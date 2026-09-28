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

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
CONTRACT_DOC="$KIT_ROOT/docs/LIFECYCLE-CONTRACT.md"

# AFK-TP-4 AC-1: same host-wide suite lock as tests/run-tests.sh, so a
# standalone run of this suite still excludes other full runs. Skipped via
# AFK_TEST_LOCK_NESTED=1 when run-tests.sh launched this as its child suite
# (it already holds the lock) or via AFK_TEST_LOCK=off for CI runners.
AFK_TEST_LOCK_MKDIR=""
afk_test_lock_acquire() {
  [[ "${AFK_TEST_LOCK:-}" == "off" || "${AFK_TEST_LOCK_NESTED:-}" == "1" ]] && return 0
  local lockdir="${AFK_TEST_LOCK_PATH:-${XDG_RUNTIME_DIR:-/tmp}/agent-flow-kit-test-suite.lock}"
  local timeout="${AFK_TEST_LOCK_TIMEOUT:-0}" waited=0 ownerpid printed=0
  local mine; mine="pid=$$ cwd=$PWD start=$(date -u +%FT%TZ)"
  if [[ "${AFK_TEST_LOCK_FORCE_MKDIR:-}" != "1" ]] && command -v flock >/dev/null 2>&1; then
    exec {AFK_TEST_LOCK_FD}<>"$lockdir"
    if ! flock -n "$AFK_TEST_LOCK_FD" 2>/dev/null; then
      printf 'waiting on suite lock, held by: %s\n' "$(cat "$lockdir" 2>/dev/null || echo unknown)"
      if (( timeout > 0 )); then
        flock -w "$timeout" "$AFK_TEST_LOCK_FD" 2>/dev/null ||
          { printf 'suite lock wait timed out after %ss\n' "$timeout" >&2; return 3; }
      else
        flock "$AFK_TEST_LOCK_FD"
      fi
    fi
    printf '%s\n' "$mine" >"$lockdir"
  else
    while ! mkdir "$lockdir.d" 2>/dev/null; do
      ownerpid="$(cat "$lockdir.d/pid" 2>/dev/null || true)"
      if [[ -n "$ownerpid" ]] && ! kill -0 "$ownerpid" 2>/dev/null; then
        if mkdir "$lockdir.d.reclaim" 2>/dev/null; then
          rm -rf "$lockdir.d"; rmdir "$lockdir.d.reclaim"
        fi
        continue
      fi
      if (( printed == 0 )); then
        printf 'waiting on suite lock, held by: %s\n' "$(cat "$lockdir.d/holder" 2>/dev/null || echo unknown)"
        printed=1
      fi
      (( timeout > 0 && waited >= timeout )) &&
        { printf 'suite lock wait timed out after %ss\n' "$timeout" >&2; return 3; }
      sleep 1; waited=$((waited + 1))
    done
    echo "$$" >"$lockdir.d/pid"
    printf '%s\n' "$mine" >"$lockdir.d/holder"
    AFK_TEST_LOCK_MKDIR="$lockdir.d"
  fi
  export AFK_TEST_LOCK_NESTED=1
  return 0
}
afk_test_lock_release() { [[ -n "$AFK_TEST_LOCK_MKDIR" ]] && rm -rf "$AFK_TEST_LOCK_MKDIR"; }
afk_test_lock_acquire; AFK_TEST_LOCK_RC=$?
(( AFK_TEST_LOCK_RC != 0 )) && exit "$AFK_TEST_LOCK_RC"

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"; afk_test_lock_release' EXIT

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
  mkdir -p "$d/adapters" "$d/bin" "$d/lib" "$d/lifecycle" "$d/files/model-router/scripts" "$d/files/humanizer/skills/humanizer"
  cat > "$d/lifecycle/kit.json" <<'JSON'
{
  "kit_id": "agent-flow-kit",
  "lifecycle_schema_version": "1.0",
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

# A complete, healthy legacy installation with user-owned content on both
# sides of the managed section.
install_kit() { # <home> <checkout>
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
    exit 1
  fi
}

# ===========================================================================
# golden fixtures (AD-21) — built once per suite process through the real
# CLI, then restored to the one fixed path they were built at instead of
# paid for again through a real `adopt` (~20 s) in every scenario that only
# needs the RESULT of adoption, never the adoption itself.
# ===========================================================================

GOLDEN_SC="$TMPROOT/sc-work"
GOLDEN_ADOPTED_STATUS=""

# The isolation guarantees a golden must keep the instant it is taken (AD-21),
# so a violation is caught here rather than laundered through every restore.
# A committed journal is deliberately retained (never absent on an adopted
# host, per journal_fingerprint above), so item 3 checks for no IN_PROGRESS
# journal and no content under stage/, not bare absence.
assert_golden_isolation() { # <name> <home>
  local name="$1" home="$2" j st
  [[ -e "$home/$STATE_DIR_REL/lock" ]] && \
    bad "fixture: golden $name has no lock dir" "found $home/$STATE_DIR_REL/lock"
  j="$home/$STATE_DIR_REL/journal.json"
  if [[ -e "$j" ]]; then
    st="$(jq -r '.state // ""' "$j" 2>/dev/null)"
    [[ "$st" == "IN_PROGRESS" ]] && \
      bad "fixture: golden $name has no in-progress journal" "journal.json state is IN_PROGRESS"
  fi
  if [[ -n "$(find "$home/$STATE_DIR_REL/stage" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    bad "fixture: golden $name has no stage leftovers" "content found under stage/"
  fi
  [[ -z "$(jobs -p)" ]] || \
    bad "fixture: golden $name build left no background process alive" "$(jobs -p)"
}

# Snapshot the scenario just built at $GOLDEN_SC into $TMPROOT/golden-<name>,
# make it read-only, and confirm the copy shares no inodes with its source
# (cp -a only, never --link/--reflink=always).
snapshot_golden() { # <name>
  cp -a "$GOLDEN_SC" "$TMPROOT/golden-$1" || bad "fixture: golden $1 snapshot" "cp -a failed"
  chmod -R a-w "$TMPROOT/golden-$1" 2>/dev/null
  [[ ! -w "$TMPROOT/golden-$1" ]] || \
    bad "fixture: golden $1 is read-only" "$TMPROOT/golden-$1 is writable"
  if [[ -n "$(find "$TMPROOT/golden-$1" -type f -links +1 -print -quit 2>/dev/null)" ]]; then
    bad "fixture: golden $1 shares no inodes with its source" "a hard-linked file was found"
  fi
}

# Restore golden <name> to the one fixed absolute path it was built at. Never
# relocated: the manifest and the ~/.claude/skills links record absolute
# paths, and a relocated copy fails PATH_ESCAPES_OWNERSHIP_BOUNDARY.
restore_golden() { # <name>
  SC="$GOLDEN_SC"; HOMEDIR="$SC/home"; CHECKOUT="$SC/checkout"
  chmod -R u+rwX "$SC" 2>/dev/null
  rm -rf "$SC"
  cp -a "$TMPROOT/golden-$1" "$SC" || { bad "fixture: golden $1 restored in place" "cp -a failed"; return 1; }
  # cp -a carries the read-only golden's mode bits onto the working copy too;
  # only the golden itself (AC-3.6) is meant to stay read-only.
  chmod -R u+rwX "$SC"
}

# Build both goldens once, through the real CLI. "installed" covers setup
# that only needs a legacy install; "adopted" additionally establishes
# ownership through a real, asserted `adopt --json`.
build_goldens() {
  SC="$GOLDEN_SC"; HOMEDIR="$SC/home"; CHECKOUT="$SC/checkout"
  mkdir -p "$HOMEDIR" "$CHECKOUT"
  make_checkout "$CHECKOUT"
  install_kit "$HOMEDIR" "$CHECKOUT"
  snapshot_golden installed
  assert_golden_isolation installed "$HOMEDIR"

  adopt_host
  run_afk status --json
  if [[ "$RUN_RC" != "0" || -z "$RUN_OUT" ]]; then
    bad "fixture: golden adopted build-time status succeeded" \
      "exit $RUN_RC: status --json produced no output to snapshot"
    exit 1
  fi
  GOLDEN_ADOPTED_STATUS="$RUN_OUT"
  git -C "$CHECKOUT" cat-file -e HEAD 2>/dev/null || \
    bad "fixture: golden adopted checkout resolves HEAD" "git objects did not copy whole"
  snapshot_golden adopted
  assert_golden_isolation adopted "$HOMEDIR"

  # AC-4 self-check: a fresh restore must observe byte-identically to the
  # build, once per suite, or the suite fails loudly before any scenario runs.
  restore_golden adopted
  run_afk status --json
  if [[ "$RUN_RC" != "0" || -z "$RUN_OUT" ]]; then
    bad "fixture: golden adopted restore self-check status succeeded" \
      "exit $RUN_RC: status --json failed after a fresh restore, not just differed"
    exit 1
  fi
  if [[ "$RUN_OUT" != "$GOLDEN_ADOPTED_STATUS" ]]; then
    bad "fixture: golden adopted restore is byte-identical to the build" \
      "status --json differs after a fresh restore"
    exit 1
  fi
}
build_goldens

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
head1 "1. The published mutation vocabulary is real"
# ===========================================================================

BAD_MSG=0; BAD_ACTION=0; MUT_COUNT=0
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  MUT_COUNT=$((MUT_COUNT + 1))
  msg="$(afk_reason_message "$code")"
  act="$(afk_reason_action "$code")"
  if [[ -z "$msg" || "$msg" == "$AFK_REASON_FALLBACK" ]]; then
    BAD_MSG=$((BAD_MSG + 1)); printf '        no specific message: %s\n' "$code"
  fi
  if [[ -z "$act" ]]; then BAD_ACTION=$((BAD_ACTION + 1)); fi
done < <(afk_mutation_reason_codes)
assert_ne "the mutation reason vocabulary is non-empty" "$MUT_COUNT" "0"
assert_eq "every mutation reason code carries a specific message" "$BAD_MSG" "0"
assert_eq "every mutation reason code carries a required action" "$BAD_ACTION" "0"
assert_eq "no code is published twice across both halves" \
  "$({ afk_reason_codes; afk_mutation_reason_codes; } | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" "0"

# ===========================================================================
head1 "2. The plan is complete, stable, falsifiable, and writes nothing"
# ===========================================================================

restore_golden installed

# On a host the lifecycle has never touched, planning creates NOTHING: not a
# manifest, not a journal, not a lock, not even the declared state directory.
run_afk adopt --plan --json
assert_eq "planning on a pristine host exits 0"     "$RUN_RC" "0"
assert_eq "and answers the question it was asked"   "$(jget '.extra.plan.command')" "adopt"
assert_no_file "and creates no kit state whatsoever" "$HOMEDIR/$STATE_DIR_REL"

restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
printf 'policy line one\npolicy line two\npolicy line three\n' > "$CHECKOUT/files/claude-global-CLAUDE.md"
git_commit_all "$CHECKOUT" "canonical v2"

FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"
JOURNAL_BEFORE="$(journal_fingerprint)"
run_afk update --plan --json
PLAN_ONE="$RUN_OUT"
assert_eq "a computable plan exits 0"                 "$RUN_RC" "0"
assert_eq "the plan declares its command"             "$(jget '.extra.plan.command')" "update"
assert_eq "the plan carries a stable identity"        "$(jget '.extra.plan.plan_identity | startswith("sha256:")')" "true"
assert_eq "the plan covers every declared component"  "$(jget '.extra.plan.components | length')" "11"
assert_eq "the plan says what must change"            "$(jget '.extra.plan.required_mutations')" "2"
assert_eq "the changed managed copy is planned for replacement" \
  "$(plan_field model-router action)" "REPLACE"
assert_eq "the changed managed section is planned for replacement" \
  "$(plan_field claude-global-policy action)" "REPLACE"
assert_eq "an unchanged component is planned as NONE" \
  "$(plan_field humanizer action)" "NONE"
assert_eq "machine-owned state is planned as PRESERVE" \
  "$(plan_field model-router-config action)" "PRESERVE"
assert_eq "every entry declares its expected final state" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.extra.plan.components[] | select(.expected_final_state == null)] | length')" "0"
assert_eq "every entry declares ownership, destination, guard, identities and protections" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.extra.plan.components[]
     | select((has("ownership") and has("destination") and has("guard")
               and has("expected_destination_identity") and has("target_identity")
               and has("applied_identity") and has("canonical_identity")
               and has("adaptation") and has("execution_critical")
               and has("backup_required") and has("requires_approval")) | not)] | length')" "0"
assert_eq "each entry carries the guard it will be revalidated against" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.extra.plan.components[] | select(.guard.expected_type == null)] | length')" "0"
assert_eq "the plan binds to the source revision" \
  "$(jget '.extra.plan.binding.source_revision')" "$(git -C "$CHECKOUT" rev-parse HEAD)"
assert_eq "the plan binds to the manifest state" \
  "$(jget '.extra.plan.binding.manifest_state_identity')" \
  "sha256:$(hash_of_file "$(manifest_path)")"
assert_eq "the plan binds to every destination observation" \
  "$(jget '.extra.plan.binding.components | length')" "11"
assert_eq "the plan binds to the prior revision" \
  "$(jget '.extra.plan.prior_revision')" "$(manifest_get '.applied_revision')"
assert_eq "computing a plan changes nothing at all" "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"
assert_eq "computing a plan opens no journal" "$(journal_fingerprint)" "$JOURNAL_BEFORE"
assert_eq "the only journal present is the closed one the adoption left" \
  "$(jq -r '.state' "$(journal_path)")" "COMMITTED"
assert_no_file "computing a plan takes no lock"     "$(lock_path)"

run_afk update --plan --json
assert_eq "the plan is byte-identical when nothing moved" "$RUN_OUT" "$PLAN_ONE"

# The identity moves when a bound input moves — that is what makes an approval
# non-transferable rather than a rubber stamp.
PLAN_ID_ONE="$(printf '%s' "$PLAN_ONE" | jq -r '.extra.plan.plan_identity')"
printf 'humanizer v2\n' > "$CHECKOUT/files/humanizer/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v3"
run_afk update --plan --json
assert_ne "a moved source produces a different plan identity" \
  "$(jget '.extra.plan.plan_identity')" "$PLAN_ID_ONE"

# The binding itself is falsifiable: recomputing it after a destination moves
# produces a different binding, which is what the mutation boundary compares.
AFK_KIT_ROOT="$CHECKOUT"
AFK_SKILLS_HOME="$HOMEDIR/.agents/skills"
AFK_CLAUDE_HOME="$HOMEDIR/.claude"
AFK_CODEX_HOME="$HOMEDIR/.codex"
AFK_MANIFEST="$(manifest_path)"
AFK_MANIFEST_JSON="{}"
AFK_ADAPT_RECORDS=""
AFK_APPLIED_REVISION=""
AFK_CO_REVISION="unit"
AFK_CO_REPO_IDENTITY="unit"
AFK_JOURNAL_STATE="NONE"
if afk_plan_binding_compute; then
  ok "the binding can be computed from the declared inventory"
else
  bad "the binding can be computed from the declared inventory" \
    "afk_plan_binding_compute failed; a binding is never allowed to come out empty"
fi
BINDING_ONE="$AFK_PLAN_BINDING"
# Anti-vacuity: an EMPTY binding would satisfy "stable over unchanged state"
# and would then also compare equal to itself at the mutation boundary, however
# far the installation moved. So the coverage is asserted before the stability.
assert_eq "the binding covers every declared component" \
  "$(printf '%s' "$BINDING_ONE" | jq -r '.components | length')" "11"
assert_eq "and every bound component carries its path observation" \
  "$(printf '%s' "$BINDING_ONE" | jq -r '[.components[] | select(.path_observation == null)] | length')" "0"
afk_plan_binding_compute
assert_eq "the binding is stable over unchanged state" "$AFK_PLAN_BINDING" "$BINDING_ONE"
printf 'a hand edit between plan and write\n' >> "$HOMEDIR/.codex/AGENTS.md"
afk_plan_binding_compute
assert_ne "and it moves the moment a managed destination moves" \
  "$AFK_PLAN_BINDING" "$BINDING_ONE"

# ===========================================================================
head1 "3. Adoption establishes ownership without touching content"
# ===========================================================================

new_scenario adopt
install_kit "$HOMEDIR" "$CHECKOUT"
CLAUDE_BEFORE="$SC/claude-before.md"
cp "$HOMEDIR/.claude/CLAUDE.md" "$CLAUDE_BEFORE"
MR_ID_BEFORE="$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")"

run_afk adopt --json
assert_eq "an auto-adoptable legacy host adopts unattended" "$RUN_RC" "0"
assert_eq "the operation reports itself as adoption"    "$(jget '.operation.result')" "ADOPTED"
assert_eq "the operation is marked mutating"            "$(jget '.operation.mutating')" "true"
assert_eq "it carries the plan identity it executed"    "$(jget '.operation.plan_identity | startswith("sha256:")')" "true"
assert_eq "the applied state was committed"             "$(jget '.operation.applied_state_committed')" "true"
assert_eq "the result was verified offline before commit" \
  "$(jget '.extra.verification.verified')" "true"
assert_eq "verification performed no live probe"        "$(jget '.extra.verification.live_probes_performed')" "false"
assert_eq "verification repaired nothing"               "$(jget '.extra.verification.repaired')" "false"
OP_ID="$(jget '.operation.id')"
assert_file "a state manifest now exists" "$(manifest_path)"
assert_eq "the manifest records the exact checkout revision" \
  "$(manifest_get '.applied_revision')" "$(git -C "$CHECKOUT" rev-parse HEAD)"
assert_eq "the manifest records the repository identity" \
  "$(manifest_get '.repository.identity')" \
  "rootcommit:$(git -C "$CHECKOUT" rev-list --max-parents=0 HEAD | tail -n1)"
assert_eq "every observable managed component is now owned" \
  "$(manifest_get '.components | keys | length')" "10"
assert_eq "machine-local state is NOT claimed as kit content" \
  "$(manifest_get '.components["model-router-config"] // "absent"')" "absent"
assert_eq "adopting changed no managed content" \
  "$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")" "$MR_ID_BEFORE"
if cmp -s "$HOMEDIR/.claude/CLAUDE.md" "$CLAUDE_BEFORE"; then
  ok "adopting changed not one byte of the shared global file"
else
  bad "adopting changed not one byte of the shared global file"
fi
assert_eq "the journal is closed after a successful transaction" \
  "$(jq -r '.state' "$(journal_path)")" "COMMITTED"
assert_absent "the journal carries no file content, only identities" \
  "$(cat "$(journal_path)")" "policy line one"
assert_no_file "temporary recovery material was cleaned up" \
  "$HOMEDIR/$STATE_DIR_REL/backups/$OP_ID"

run_afk status --json
assert_eq "the adopted host is now CURRENT" "$(jget '.installed.state')" "CURRENT"
assert_eq "and reports itself adopted"      "$(jget '.installed.adopted')" "true"
assert_eq "status exits 0"                  "$RUN_RC" "0"

run_afk verify --json
assert_eq "offline verify proves the installed state" "$(jget '.extra.verification.verified')" "true"
assert_eq "and exits 0"                               "$RUN_RC" "0"
assert_eq "every component check passed" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.extra.verification.checks[]
     | select(.check == "component_integrity" and .result == "FAIL")] | length')" "0"

run_afk adopt --json
assert_eq "adopting an adopted host refuses" "$RUN_RC" "2"
assert_eq "with a stable reason"             "$(jget '.operation.reason')" "ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED"
assert_eq "and performs no mutation"         "$(jget '.operation.mutation_performed')" "false"

# --- adoption that crosses an ownership boundary needs an owner ------------
new_scenario adoptapproval
install_kit "$HOMEDIR" "$CHECKOUT"
printf 'hand-written local guidance nobody recorded\n' > "$HOMEDIR/.codex/AGENTS.md"
CODEX_BEFORE="$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")"
run_afk adopt --json
assert_eq "unrecognized content requires approval" "$RUN_RC" "2"
assert_eq "the operation says so"                  "$(jget '.operation.result')" "APPROVAL_REQUIRED"
assert_eq "with a stable reason"                   "$(jget '.operation.reason')" "PLAN_APPROVAL_REQUIRED"
assert_eq "the plan names the component that needs the decision" \
  "$(plan_field codex-global-guidance requires_approval)" "true"
assert_eq "and what it proposes to do with it" \
  "$(plan_field codex-global-guidance action)" "CLAIM"
assert_eq "and the exact content it would preserve" \
  "$(plan_field codex-global-guidance target_identity)" "sha256:$CODEX_BEFORE"
assert_eq "and the state that would result" \
  "$(plan_field codex-global-guidance expected_final_state)" "UPDATE_AVAILABLE"
assert_no_file "no manifest was created" "$(manifest_path)"
assert_no_file "no journal was written"  "$(journal_path)"
assert_eq "and nothing was mutated"      "$(jget '.operation.mutation_performed')" "false"

APPROVE_ID="$(jget '.extra.plan.plan_identity')"
run_afk adopt --json --approve-plan "sha256:0000000000000000000000000000000000000000000000000000000000000000"
assert_eq "an approval for another plan authorizes nothing" "$RUN_RC" "2"
assert_eq "with a stable reason" "$(jget '.operation.reason')" "PLAN_APPROVAL_MISMATCH"
assert_no_file "and still no manifest" "$(manifest_path)"

run_afk adopt --json --approve-plan "$APPROVE_ID"
assert_eq "the exact approved plan is authorized" "$RUN_RC" "0"
assert_eq "and it adopts"                         "$(jget '.operation.result')" "ADOPTED"
assert_eq "the approved content is preserved byte for byte" \
  "$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")" "$CODEX_BEFORE"
assert_eq "and is recorded at exactly that identity" \
  "$(manifest_get '.components["codex-global-guidance"].identity')" "sha256:$CODEX_BEFORE"

# --- an approval never transfers to a recomputed plan ----------------------
new_scenario approvalinvalidation
install_kit "$HOMEDIR" "$CHECKOUT"
printf 'hand-written local guidance nobody recorded\n' > "$HOMEDIR/.codex/AGENTS.md"
run_afk adopt --plan --json
STALE_APPROVAL="$(jget '.extra.plan.plan_identity')"
assert_eq "the plan requires approval" "$(jget '.extra.plan.disposition')" "APPROVAL_REQUIRED"
assert_eq "which is an owner-action exit even in plan-only mode" "$RUN_RC" "2"
# An authority-relevant input moves: the canonical source advances.
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
run_afk adopt --json --approve-plan "$STALE_APPROVAL"
assert_eq "the earlier approval no longer authorizes anything" "$RUN_RC" "2"
assert_eq "and says exactly why" "$(jget '.operation.reason')" "PLAN_APPROVAL_MISMATCH"
assert_no_file "no manifest was created under the stale approval" "$(manifest_path)"

# --- adoption refuses where ownership cannot be distinguished -------------
new_scenario adoptrefuse
install_kit "$HOMEDIR" "$CHECKOUT"
mkdir -p "$SC/elsewhere"
printf 'redirected %s\n' "$SENTINEL" > "$SC/elsewhere/stolen.md"
rm -f "$HOMEDIR/.codex/AGENTS.md"
ln -s "$SC/elsewhere/stolen.md" "$HOMEDIR/.codex/AGENTS.md"
run_afk adopt --json
assert_eq "a redirected destination refuses adoption" "$RUN_RC" "2"
assert_eq "the plan is a refusal" "$(jget '.extra.plan.disposition')" "REFUSED"
assert_eq "naming the guard that fired" \
  "$(plan_field codex-global-guidance reason)" "PATH_UNEXPECTED_SYMLINK"
assert_eq "and nothing was mutated" "$(jget '.operation.mutation_performed')" "false"
assert_no_file "and no manifest was created" "$(manifest_path)"
assert_absent "nothing behind the redirection was read" "$RUN_OUT" "$SENTINEL"

# --- an ineligible source cannot be adopted from --------------------------
new_scenario adoptineligible
install_kit "$HOMEDIR" "$CHECKOUT"
printf 'scratch\n' > "$CHECKOUT/files/scratch-dirty.txt"
run_afk adopt --json
assert_eq "an ineligible source is a precondition refusal" "$RUN_RC" "4"
assert_eq "with its own reason" "$(jget '.operation.reason')" "SOURCE_INELIGIBLE"
assert_no_file "and nothing was written" "$HOMEDIR/$STATE_DIR_REL"

# ===========================================================================
head1 "4. Update converges only what it owns"
# ===========================================================================

restore_golden adopted
OLD_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

# The host carries machine-local configuration and user-owned content on both
# sides of the managed section. Neither may move.
printf 'launcher:\n  router_endpoint: https://this-host.invalid\n  token: %s\n' "$SENTINEL" \
  > "$HOMEDIR/.agents/skills/model-router/subscriptions.yaml"
LOCAL_CONFIG_ID="$(hash_of_file "$HOMEDIR/.agents/skills/model-router/subscriptions.yaml")"
printf '\n# a late personal note\n' >> "$HOMEDIR/.claude/CLAUDE.md"
OUTSIDE_BEFORE="$(outside_id "$HOMEDIR/.claude/CLAUDE.md" claude-global-policy)"

printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
printf 'policy line one\npolicy line two\npolicy line three\n' > "$CHECKOUT/files/claude-global-CLAUDE.md"
printf 'codex guidance v2\n' > "$CHECKOUT/files/codex-AGENTS.md"
git_commit_all "$CHECKOUT" "canonical v2"
NEW_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

run_afk update --json
assert_eq "an ordinary convergence succeeds"        "$RUN_RC" "0"
assert_eq "and reports itself converged"            "$(jget '.operation.result')" "CONVERGED"
assert_eq "the prior revision is recorded"          "$(jget '.operation.prior_revision')" "$OLD_SHA"
assert_eq "the applied revision advanced"           "$(jget '.operation.applied_revision')" "$NEW_SHA"
assert_eq "the manifest now carries the target revision" \
  "$(manifest_get '.applied_revision')" "$NEW_SHA"
assert_eq "the result was verified offline"         "$(jget '.extra.verification.verified')" "true"
assert_eq "every write is recorded as a completed step" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.operation.completed_steps[] | select(.result == "APPLIED")] | length')" "3"
assert_eq "kit-owned tree content converged" \
  "$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")" \
  "$(hash_of_file "$CHECKOUT/files/model-router/SKILL.md")"
assert_eq "kit-owned file content converged" \
  "$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")" \
  "$(hash_of_file "$CHECKOUT/files/codex-AGENTS.md")"
assert_eq "machine-local configuration survived the managed-copy upgrade" \
  "$(hash_of_file "$HOMEDIR/.agents/skills/model-router/subscriptions.yaml")" "$LOCAL_CONFIG_ID"
assert_eq "content outside the managed section is byte-identical" \
  "$(outside_id "$HOMEDIR/.claude/CLAUDE.md" claude-global-policy)" "$OUTSIDE_BEFORE"
assert_eq "the managed section itself carries the new canonical payload" \
  "$(grep -c 'policy line three' "$HOMEDIR/.claude/CLAUDE.md")" "1"
assert_eq "the user's first line is still the first line" \
  "$(head -n 1 "$HOMEDIR/.claude/CLAUDE.md")" "# my own notes, owned by me"
assert_eq "the user's last line is still the last line" \
  "$(tail -n 1 "$HOMEDIR/.claude/CLAUDE.md")" "# a late personal note"
assert_absent "no secret from a machine-local file reached the output" "$RUN_OUT" "$SENTINEL"
assert_absent "and none reached the journal"  "$(cat "$(journal_path)")" "$SENTINEL"
assert_absent "and none reached the manifest" "$(cat "$(manifest_path)")" "$SENTINEL"

run_afk verify --json
assert_eq "the converged host verifies" "$(jget '.extra.verification.verified')" "true"
assert_eq "and exits 0"                 "$RUN_RC" "0"

# --- idempotence: reapplying the same revision is a no-op -----------------
FP_AFTER="$(fingerprint_tree "$HOMEDIR")"
MANIFEST_HASH="$(hash_of_file "$(manifest_path)")"
run_afk update --json
assert_eq "reapplying the applied revision is a no-op"  "$RUN_RC" "0"
assert_eq "and says so"                                 "$(jget '.operation.result')" "NO_CHANGE"
assert_eq "with a stable reason"                        "$(jget '.operation.reason')" "PLAN_NO_CHANGE_REQUIRED"
assert_eq "the plan requires no mutation"               "$(jget '.extra.plan.required_mutations')" "0"
assert_eq "no mutation was performed"                   "$(jget '.operation.mutation_performed')" "false"
assert_eq "the installation experienced no churn"       "$(fingerprint_tree "$HOMEDIR")" "$FP_AFTER"
assert_eq "the manifest was not rewritten"              "$(hash_of_file "$(manifest_path)")" "$MANIFEST_HASH"
assert_eq "the applied revision is unchanged"           "$(manifest_get '.applied_revision')" "$NEW_SHA"

# --- a component that is absent is installed, never claimed ---------------
restore_golden installed
rm -f "$HOMEDIR/.codex/AGENTS.md"
adopt_host
assert_eq "an absent component is not recorded by adoption" \
  "$(manifest_get '.components["codex-global-guidance"] // "absent"')" "absent"
run_afk update --json
assert_eq "update installs it"          "$RUN_RC" "0"
assert_eq "the plan called it INSTALL"  "$(plan_field codex-global-guidance action)" "INSTALL"
assert_file "and the destination exists now" "$HOMEDIR/.codex/AGENTS.md"
assert_eq "with canonical content" \
  "$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")" "$(hash_of_file "$CHECKOUT/files/codex-AGENTS.md")"
assert_eq "and it is now owned" \
  "$(manifest_get '.components["codex-global-guidance"].identity')" \
  "sha256:$(hash_of_file "$CHECKOUT/files/codex-AGENTS.md")"

# --- a managed section that is absent is inserted, preserving the file ----
restore_golden installed
printf '# only my own notes here\nnothing managed yet\n' > "$HOMEDIR/.claude/CLAUDE.md"
cp "$HOMEDIR/.claude/CLAUDE.md" "$SC/claude-before.md"
adopt_host
assert_eq "an absent section is not adopted as owned" \
  "$(manifest_get '.components["claude-global-policy"] // "absent"')" "absent"
run_afk update --json
assert_eq "update inserts the managed section" "$RUN_RC" "0"
assert_eq "the plan called it INSTALL"         "$(plan_field claude-global-policy action)" "INSTALL"
assert_eq "the user's file is still the head of the result" \
  "$(head -n 2 "$HOMEDIR/.claude/CLAUDE.md")" "$(cat "$SC/claude-before.md")"
assert_eq "the section now carries canonical content" \
  "$(grep -c 'policy line two' "$HOMEDIR/.claude/CLAUDE.md")" "1"
run_afk verify --json
assert_eq "and the host verifies afterwards" "$(jget '.extra.verification.verified')" "true"

# ===========================================================================
head1 "5. Drift, adaptations and redirection block replacement"
# ===========================================================================

restore_golden adopted
ADOPTED_SHA="$(manifest_get '.applied_revision')"
JOURNAL_AFTER_ADOPT="$(journal_fingerprint)"
printf 'edited by hand\n' >> "$HOMEDIR/.agents/skills/model-router/SKILL.md"
DRIFTED_ID="$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")"
CODEX_INSTALLED="$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")"
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
printf 'codex guidance v2\n' > "$CHECKOUT/files/codex-AGENTS.md"
git_commit_all "$CHECKOUT" "canonical v2"

run_afk update --json
assert_eq "unexplained drift refuses convergence" "$RUN_RC" "2"
assert_eq "the plan blocks that component"        "$(plan_field model-router action)" "BLOCKED"
assert_eq "with a stable reason"                  "$(plan_field model-router reason)" "UNEXPLAINED_MANAGED_DIFFERENCE"
assert_eq "and no mutation was performed"         "$(jget '.operation.mutation_performed')" "false"
assert_eq "the drifted file was not overwritten" \
  "$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")" "$DRIFTED_ID"
assert_eq "the applied revision did not move"     "$(manifest_get '.applied_revision')" "$ADOPTED_SHA"
# The conflict was known during preflight, so no recovery journal was opened:
# the journal on disk is still, byte for byte, the closed one the adoption left.
assert_eq "and no journal was opened for the refused plan" \
  "$(journal_fingerprint)" "$JOURNAL_AFTER_ADOPT"
# One blocked component blocks the whole plan: convergence is never partial,
# so a component that WOULD have converged is left alone too.
assert_eq "a healthy component was planned for replacement" \
  "$(plan_field codex-global-guidance action)" "REPLACE"
assert_eq "but was not converged around the conflict" \
  "$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")" "$CODEX_INSTALLED"

# The canary restores: put the recorded content back and the host is healthy.
printf 'model-router skill v1\n' > "$HOMEDIR/.agents/skills/model-router/SKILL.md"
run_afk verify --json
assert_eq "restoring the recorded content verifies clean" \
  "$(jget '.extra.verification.verified')" "true"
run_afk update --json
assert_eq "and convergence then succeeds" "$RUN_RC" "0"
assert_eq "with the canonical content"    \
  "$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")" \
  "$(hash_of_file "$CHECKOUT/files/model-router/SKILL.md")"

# --- registered adaptations are honoured exactly as declared --------------
restore_golden adopted
MR_DEST="$HOMEDIR/.agents/skills/model-router"
BASELINE_ID="$(manifest_get '.components["model-router"].identity')"
printf 'a deliberate local patch\n' >> "$MR_DEST/SKILL.md"
ADAPTED_ID="$(tree_id "$MR_DEST" subscriptions.yaml)"
assert_ne "the local patch really moved the identity" "$ADAPTED_ID" "$BASELINE_ID"
manifest_patch ".adaptations = [{
  id: \"local-patch-1\",
  component: \"model-router\",
  location: \"$MR_DEST\",
  type: \"tree-content\",
  reason: \"host-specific note appended by the owner\",
  expected_identity: \"$ADAPTED_ID\",
  disposition: \"PRESERVE\"
}]"
printf 'humanizer v2\n' > "$CHECKOUT/files/humanizer/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
PATCHED="$(hash_of_file "$MR_DEST/SKILL.md")"

run_afk update --json
assert_eq "a PRESERVE adaptation is preserved through an update" "$RUN_RC" "0"
assert_eq "the plan says PRESERVE"        "$(plan_field model-router action)" "PRESERVE"
assert_eq "and names the record"          "$(plan_field model-router adaptation)" "local-patch-1"
assert_eq "the adapted content is untouched" "$(hash_of_file "$MR_DEST/SKILL.md")" "$PATCHED"
assert_eq "while the rest of the host converged" \
  "$(hash_of_file "$HOMEDIR/.agents/skills/humanizer/SKILL.md")" \
  "$(hash_of_file "$CHECKOUT/files/humanizer/SKILL.md")"
assert_eq "the adaptation record survived the commit" \
  "$(manifest_get '.adaptations | length')" "1"
# The manifest keeps recording the canonical BASELINE, not the adapted bytes:
# an exception must not quietly become the thing the next update replaces.
assert_eq "the recorded identity is still the baseline, not the adaptation" \
  "$(manifest_get '.components["model-router"].identity')" "$BASELINE_ID"
run_afk status --json
assert_eq "so the component still reports itself as a local adaptation" \
  "$(component_field model-router .state)" "LOCAL_ADAPTATION"
run_afk update --json
assert_eq "and a second update preserves it again rather than replacing it" \
  "$(plan_field model-router action)" "PRESERVE"
assert_eq "the adapted content is still untouched" "$(hash_of_file "$MR_DEST/SKILL.md")" "$PATCHED"

manifest_patch '.adaptations[0].disposition = "OWNER_REVIEW"'
printf 'model-router skill v3\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v3"
run_afk update --json
assert_eq "an OWNER_REVIEW adaptation blocks unattended convergence" "$RUN_RC" "2"
assert_eq "with its own reason" "$(plan_field model-router reason)" "ADAPTATION_OWNER_REVIEW"
assert_eq "and nothing was written" "$(jget '.operation.mutation_performed')" "false"

manifest_patch '.adaptations[0].disposition = "REEVALUATE"'
run_afk update --json
assert_eq "a REEVALUATE adaptation asks for a decision once canonical moves" "$RUN_RC" "2"
assert_eq "with its own reason" "$(plan_field model-router reason)" "ADAPTATION_REEVALUATION_REQUIRED"

manifest_patch '.adaptations[0].expected_identity = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
run_afk update --json
assert_eq "a stale adaptation legitimizes nothing" "$RUN_RC" "2"
assert_eq "and the difference is drift again" \
  "$(plan_field model-router reason)" "UNEXPLAINED_MANAGED_DIFFERENCE"

manifest_patch '.adaptations[0].type = "link-target"'
run_afk update --json
assert_eq "an invalid adaptation record refuses the whole plan" "$RUN_RC" "2"
assert_eq "with a stable reason" "$(jget '.extra.plan.refusal_reason')" "ADAPTATION_MALFORMED"

# --- a symlink attack on a managed destination ----------------------------
restore_golden adopted
mkdir -p "$SC/outside"
printf 'somebody elses file %s\n' "$SENTINEL" > "$SC/outside/target.md"
OUTSIDE_ID="$(hash_of_file "$SC/outside/target.md")"
rm -f "$HOMEDIR/.codex/AGENTS.md"
ln -s "$SC/outside/target.md" "$HOMEDIR/.codex/AGENTS.md"
printf 'codex guidance v2\n' > "$CHECKOUT/files/codex-AGENTS.md"
git_commit_all "$CHECKOUT" "canonical v2"

run_afk update --json
assert_eq "a redirected managed destination refuses the plan" "$RUN_RC" "2"
assert_eq "the guard reason is carried into the plan" \
  "$(plan_field codex-global-guidance reason)" "PATH_UNEXPECTED_SYMLINK"
assert_eq "the file behind the redirection was NOT written through" \
  "$(hash_of_file "$SC/outside/target.md")" "$OUTSIDE_ID"
assert_absent "and its content never reached the output" "$RUN_OUT" "$SENTINEL"
assert_eq "no mutation was performed at all" "$(jget '.operation.mutation_performed')" "false"

# A symlinked PARENT directory is caught the same way.
restore_golden adopted
mkdir -p "$SC/outside"
mv "$HOMEDIR/.claude/skills" "$SC/outside/skills"
ln -s "$SC/outside/skills" "$HOMEDIR/.claude/skills"
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
run_afk update --json
assert_eq "a redirected parent directory refuses the plan" "$RUN_RC" "2"
assert_eq "with the containment reason" \
  "$(plan_field model-router-claude-link reason)" "PATH_PARENT_ESCAPES_BOUNDARY"
assert_eq "and nothing was written" "$(jget '.operation.mutation_performed')" "false"

# ===========================================================================
head1 "6. Overlapping operations are prevented, never interleaved"
# ===========================================================================

restore_golden adopted
BEFORE_SHA="$(manifest_get '.applied_revision')"
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
MR_BEFORE="$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")"

# A lock is an operation in progress only when its owner is provably alive, so
# the fixture holds it the way a running operation does.
write_live_lock
run_afk update --json
assert_eq "an operation already in progress prevents a second one" "$RUN_RC" "2"
assert_eq "with a stable reason" "$(jget '.operation.reason')" "CONCURRENT_OPERATION_IN_PROGRESS"
assert_eq "and nothing was written" \
  "$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")" "$MR_BEFORE"
assert_eq "the applied revision did not move" "$(manifest_get '.applied_revision')" "$BEFORE_SHA"

run_afk status --json
assert_eq "read-only status reports the lock"  "$(jget '.installed.lock_state')" "HELD"
assert_eq "and does not call the installation stably healthy" \
  "$(jget '.installed.state')" "INTERRUPTED"
assert_eq "which is a deterministic not-ready" "$RUN_RC" "3"
assert_eq "the finding is marked transient" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[] | select(.reason == "CONCURRENT_OPERATION_IN_PROGRESS") | .transient] | .[0]')" "true"

run_afk verify --json
assert_eq "verification refuses to call a mid-operation host verified" \
  "$(jget '.extra.verification.verified')" "false"

# A lock is a directory holding its owner record, so clearing it is a recursive
# removal — the same thing afk_lock_release does.
rm -rf "$(lock_path)"
run_afk update --json
assert_eq "once the lock clears the update proceeds" "$RUN_RC" "0"
assert_no_file "and the lock is released afterwards" "$(lock_path)"

# ===========================================================================
head1 "7. Failure leaves the applied revision where it was"
# ===========================================================================

# An injected mid-operation failure. The canonical source of a LATER component
# carries a symlink that escapes the managed tree once copied: the plan cannot
# see it (the source hashes fine), the write does — which is exactly the shape
# of a failure that lands between two component writes.
restore_golden adopted
GOOD_SHA="$(manifest_get '.applied_revision')"
MR_ID="$(tree_id "$HOMEDIR/.agents/skills/model-router" subscriptions.yaml)"
HUM_ID="$(tree_id "$HOMEDIR/.agents/skills/humanizer")"
CLAUDE_MD_ID="$(hash_of_file "$HOMEDIR/.claude/CLAUDE.md")"

printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
mkdir -p "$SC/faraway"
printf 'far away\n' > "$SC/faraway/thing.md"
ln -s "$SC/faraway/thing.md" "$CHECKOUT/files/humanizer/escape.md"
git_commit_all "$CHECKOUT" "canonical v2 with an escaping link"

run_afk update --json
assert_eq "the failed convergence is reported as rolled back" "$(jget '.operation.result')" "ROLLED_BACK"
assert_eq "which is a deterministic not-ready exit"           "$RUN_RC" "3"
assert_eq "restoration completed"                             "$(jget '.operation.rollback_state')" "COMPLETE"
assert_eq "the applied revision stayed at the prior revision" \
  "$(manifest_get '.applied_revision')" "$GOOD_SHA"
assert_eq "no applied state was committed" "$(jget '.operation.applied_state_committed')" "false"
assert_eq "the component written before the failure was restored exactly" \
  "$(tree_id "$HOMEDIR/.agents/skills/model-router" subscriptions.yaml)" "$MR_ID"
assert_eq "the component that failed is back at its prior identity" \
  "$(tree_id "$HOMEDIR/.agents/skills/humanizer")" "$HUM_ID"
assert_eq "the shared global file was never touched" \
  "$(hash_of_file "$HOMEDIR/.claude/CLAUDE.md")" "$CLAUDE_MD_ID"
assert_eq "the journal records the operation as closed" \
  "$(jq -r '.state' "$(journal_path)")" "COMMITTED"

run_afk verify --json
assert_eq "the restored installation verifies against the unchanged revision" \
  "$(jget '.extra.verification.verified')" "true"
assert_eq "and exits 0" "$RUN_RC" "0"

# ===========================================================================
head1 "8. An interrupted operation is resolved before any new mutation"
# ===========================================================================

restore_golden adopted
SAFE_SHA="$(manifest_get '.applied_revision')"
CODEX_GOOD="$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")"

# Simulate a process killed mid-transaction: a backup exists, the journal says
# a write was attempted, and the destination carries half-applied content.
BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-interrupted"
mkdir -p "$BACKUPS"
cp "$HOMEDIR/.codex/AGENTS.md" "$BACKUPS/codex-global-guidance"
PRE_CODEX="$(file_id "$HOMEDIR/.codex/AGENTS.md")"
printf 'half applied content\n' > "$HOMEDIR/.codex/AGENTS.md"
HALF_APPLIED="$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")"
write_journal "$BACKUPS" codex-global-guidance REPLACE "$HOMEDIR/.codex/AGENTS.md" "$PRE_CODEX"

run_afk status --json
assert_eq "status reports the interruption"   "$(jget '.installed.state')" "INTERRUPTED"
assert_eq "and never calls it stably healthy" "$(jget '.overall.state')" "NEEDS_OWNER"
assert_eq "read-only status repaired nothing" \
  "$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")" "$HALF_APPLIED"

run_afk update --json
assert_eq "the next lifecycle command rolls it back first" "$(jget '.operation.result')" "RECOVERED"
assert_eq "which is a deterministic not-ready exit"        "$RUN_RC" "3"
assert_eq "the destination is back at its pre-operation content" \
  "$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")" "$CODEX_GOOD"
assert_eq "the applied revision never moved" "$(manifest_get '.applied_revision')" "$SAFE_SHA"
assert_eq "the journal is closed"            "$(jq -r '.state' "$(journal_path)")" "COMMITTED"
assert_eq "no new mutation was attempted"    "$(jget '.operation.mutation_performed')" "false"

run_afk update --json
assert_eq "and the following run proceeds normally" "$RUN_RC" "0"

# --- recovery material that is gone stops with an owner decision ----------
restore_golden adopted
write_journal "/nonexistent/backups" codex-global-guidance REPLACE \
  "$HOMEDIR/.codex/AGENTS.md" "$(file_id "$HOMEDIR/.codex/AGENTS.md")"
run_afk update --json
assert_eq "an unrecoverable interruption needs its owner" "$RUN_RC" "2"
assert_eq "and says so"                    "$(jget '.operation.result')" "UNRECOVERABLE"
assert_eq "no new mutation was attempted"  "$(jget '.operation.mutation_performed')" "false"
assert_eq "the journal is left open as evidence" \
  "$(jq -r '.state' "$(journal_path)")" "IN_PROGRESS"

# --- an interrupted operation that wrote nothing is simply closed ---------
restore_golden adopted
jq -n '{journal_schema_version: "2.0", state: "IN_PROGRESS", operation_id: "op-nothing",
        command: "update", backup_dir: null, rollback_state: "NOT_REQUIRED",
        pre_mutation: [], plan: {components: []}, completed_steps: []}' > "$(journal_path)"
run_afk update --json
assert_eq "an interruption before the first write is recoverable" \
  "$(jget '.operation.result')" "RECOVERED"
assert_eq "and the journal is closed" "$(jq -r '.state' "$(journal_path)")" "COMMITTED"

# ===========================================================================
head1 "9. Verification observes, and never repairs"
# ===========================================================================

restore_golden adopted
printf 'edited by hand\n' >> "$HOMEDIR/.agents/skills/model-router/SKILL.md"
DRIFTED="$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")"
FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"

run_afk verify --json
assert_eq "drift makes verification fail"      "$(jget '.extra.verification.verified')" "false"
assert_ne "and the command does not succeed"   "$RUN_RC" "0"
assert_eq "the failing check names the component" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.extra.verification.checks[]
     | select(.result == "FAIL") | .subject] | index("model-router") != null')" "true"
assert_eq "verification repaired nothing" \
  "$(hash_of_file "$HOMEDIR/.agents/skills/model-router/SKILL.md")" "$DRIFTED"
assert_eq "and changed nothing at all" "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"

# Verification never probes a live service.
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
HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
  PATH="$STUBBIN:$PATH" AGENT_ROUTER_URL="https://router.invalid" \
  AGENT_ROUTER_TOKEN="$SENTINEL" bash "$AFK" verify --json >"$SC/verify.json" 2>/dev/null
assert_no_file "verify invoked no external binary" "$SC/live-probe-marker"
assert_absent  "and leaked no secret" "$(cat "$SC/verify.json")" "$SENTINEL"

# Installed integrity and source eligibility stay independent (NFR-12): a
# manifest whose recorded revision is unreachable from THIS checkout still
# describes installed content that can be proven.
restore_golden adopted
manifest_patch '.applied_revision = "0000000000000000000000000000000000000000"'
run_afk verify --json
assert_eq "installed content still verifies against what the manifest records" \
  "$(jget '.extra.verification.verified')" "true"
run_afk update --json
assert_eq "but an unreachable applied revision blocks mutation" "$RUN_RC" "4"
assert_eq "as a source precondition, not an installation failure" \
  "$(jget '.operation.reason')" "SOURCE_INELIGIBLE"
assert_eq "and nothing was mutated" "$(jget '.operation.mutation_performed')" "false"

restore_golden installed
run_afk verify --json
assert_eq "an unadopted host has nothing to verify" "$(jget '.extra.verification.verified')" "false"
assert_eq "with a stable reason" \
  "$(printf '%s' "$RUN_OUT" | jq -r '.extra.verification.checks[0].reason')" "INSTALLATION_NOT_ADOPTED"
assert_ne "and it does not exit successfully" "$RUN_RC" "0"
run_afk update --json
assert_eq "update on an unadopted host refuses" "$RUN_RC" "2"
assert_eq "with a stable reason" "$(jget '.extra.plan.refusal_reason')" "INSTALLATION_NOT_ADOPTED"
assert_no_file "and writes nothing" "$HOMEDIR/$STATE_DIR_REL"

# ===========================================================================
head1 "10. The mutating contract is machine-readable and projected"
# ===========================================================================

restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
run_afk update --json
UPDATE_JSON="$RUN_OUT"

assert_eq "the operation is fully described" \
  "$(printf '%s' "$UPDATE_JSON" | jq -r '[.operation
     | select((has("id") and has("result") and has("reason") and has("plan_identity")
               and has("mutation_performed") and has("applied_state_committed")
               and has("rollback_state") and has("prior_revision")
               and has("applied_revision") and has("completed_steps")) | not)] | length')" "0"
assert_eq "every completed step names its component, action and result" \
  "$(printf '%s' "$UPDATE_JSON" | jq -r '[.operation.completed_steps[]
     | select((has("component") and has("action") and has("result")) | not)] | length')" "0"

# ===========================================================================
head1 "10. Adversarial-review regressions F1-F8"
# ===========================================================================

# --- F1: the journal is evidence, never destructive authority --------------
#
# The reported failure: recovery replayed completed_steps[].destination
# verbatim and, finding no stored copy, treated "restore" as "remove". A state
# directory cleanup that empties backups/op-XXXX/ while leaving the directory,
# or a journal naming a path the inventory no longer declares, then turned the
# next ordinary update into an unbounded rm -rf of paths the lifecycle never
# owned — reported as RECOVERED, with the journal closed and the evidence
# deleted behind it.

# (a) backup directory present, per-component store absent.
restore_golden adopted
VICTIM_DIR="$HOMEDIR/Documents/taxes"
mkdir -p "$VICTIM_DIR"
printf 'my 2025 tax return, owned by me\n' > "$VICTIM_DIR/2025.txt"
VICTIM_ID="$(hash_of_file "$VICTIM_DIR/2025.txt")"
EMPTY_BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-emptied"
mkdir -p "$EMPTY_BACKUPS"
CODEX_NOW="$(file_id "$HOMEDIR/.codex/AGENTS.md")"
write_journal "$EMPTY_BACKUPS" codex-global-guidance REPLACE \
  "$HOMEDIR/.codex/AGENTS.md" "$CODEX_NOW"
FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"

run_afk update --json
assert_eq "F1a a recorded step with no stored copy needs its owner" \
  "$(jget '.operation.result')" "UNRECOVERABLE"
assert_eq "F1a and says the authority was insufficient" \
  "$(jget '.operation.reason')" "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT"
assert_eq "F1a it is not reported as a successful recovery" \
  "$(jget '.operation.result')" "UNRECOVERABLE"
assert_eq "F1a the journal is retained as evidence" \
  "$(jq -r '.state' "$(journal_path)")" "IN_PROGRESS"
assert_file "F1a and so is the recovery directory" "$EMPTY_BACKUPS"
assert_eq "F1a nothing on the host was touched" "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"

# (b) a journal step naming a destination the inventory does not declare.
restore_golden adopted
OUTSIDE="$SC/outside"
mkdir -p "$OUTSIDE"
printf 'notes nobody asked the lifecycle to manage\n' > "$OUTSIDE/notes.txt"
BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-undeclared"
mkdir -p "$BACKUPS"
write_journal "$BACKUPS" not-a-declared-component INSTALL "$OUTSIDE/notes.txt" ""
run_afk update --json
assert_eq "F1b an undeclared component id refuses" \
  "$(jget '.operation.reason')" "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT"
assert_file "F1b and the unmanaged path is still there" "$OUTSIDE/notes.txt"

# (c) a declared component whose recorded destination is not the declared one.
restore_golden adopted
OUTSIDE="$SC/outside"
mkdir -p "$OUTSIDE"
printf 'still not the lifecycle to remove\n' > "$OUTSIDE/notes.txt"
BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-moved"
mkdir -p "$BACKUPS"
write_journal "$BACKUPS" codex-global-guidance INSTALL "$OUTSIDE/notes.txt" ""
run_afk update --json
assert_eq "F1c a destination the inventory does not declare refuses" \
  "$(jget '.operation.reason')" "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT"
assert_file "F1c and the named path is untouched" "$OUTSIDE/notes.txt"

# (d) a backup directory outside the declared backup root.
restore_golden adopted
FOREIGN="$SC/foreign-backups"
mkdir -p "$FOREIGN"
cp "$HOMEDIR/.codex/AGENTS.md" "$FOREIGN/codex-global-guidance"
write_journal "$FOREIGN" codex-global-guidance REPLACE \
  "$HOMEDIR/.codex/AGENTS.md" "$(file_id "$HOMEDIR/.codex/AGENTS.md")"
run_afk update --json
assert_eq "F1d a backup directory outside the declared state directory refuses" \
  "$(jget '.operation.reason')" "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT"

# (e) a restoration whose result does not match the recorded pre-mutation
#     identity is a verification failure, not a recovery.
restore_golden adopted
BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-wrong"
mkdir -p "$BACKUPS"
printf 'not what the journal says was there\n' > "$BACKUPS/codex-global-guidance"
write_journal "$BACKUPS" codex-global-guidance REPLACE \
  "$HOMEDIR/.codex/AGENTS.md" "0000000000000000000000000000000000000000000000000000000000000000"
run_afk update --json
assert_eq "F1e an unverifiable restoration needs its owner" \
  "$(jget '.operation.result')" "UNRECOVERABLE"
assert_eq "F1e and names the verification, not a recovery" \
  "$(jget '.operation.reason')" "OPERATION_RECOVERY_VERIFICATION_FAILED"
assert_eq "F1e the journal is retained" "$(jq -r '.state' "$(journal_path)")" "IN_PROGRESS"
assert_file "F1e and so are the backups" "$BACKUPS/codex-global-guidance"

# (f) a journal at an unsupported schema is refused, not interpreted.
restore_golden adopted
BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-oldschema"
mkdir -p "$BACKUPS"
jq -n --arg b "$BACKUPS" --arg d "$HOMEDIR/.codex/AGENTS.md" \
  '{journal_schema_version: "1.0", state: "IN_PROGRESS", operation_id: "op-old",
    command: "update", backup_dir: $b, rollback_state: "IN_PROGRESS",
    completed_steps: [{component: "codex-global-guidance", action: "REPLACE",
                       result: "ATTEMPTED", destination: $d}]}' > "$(journal_path)"
CODEX_BEFORE="$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")"
run_afk update --json
assert_eq "F1f an unsupported journal schema refuses" \
  "$(jget '.operation.reason')" "OPERATION_JOURNAL_SCHEMA_UNSUPPORTED"
assert_eq "F1f and nothing was restored from it" \
  "$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")" "$CODEX_BEFORE"

# (g) the authorized removal still works: observed_identity null, matched to
#     this exact component and this exact INSTALL binding.
restore_golden installed
rm -f "$HOMEDIR/.codex/AGENTS.md"
adopt_host
printf 'created by the interrupted install\n' > "$HOMEDIR/.codex/AGENTS.md"
BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-install"
mkdir -p "$BACKUPS"
write_journal "$BACKUPS" codex-global-guidance INSTALL "$HOMEDIR/.codex/AGENTS.md" ""
run_afk update --json
assert_eq "F1g a proven INSTALL with no prior content is rolled back" \
  "$(jget '.operation.result')" "RECOVERED"
assert_no_file "F1g by removing exactly what the operation created" \
  "$HOMEDIR/.codex/AGENTS.md"

# --- F2: applied_revision is what this host applied, on every path ----------
#
# The reported failure: AFK_OP_APPLIED_REVISION was set to the target before
# the final verification and the commit, so a completed rollback reported the
# TARGET revision beside prior_revision — the obvious reading being "this run
# advanced the host", on exactly the paths where it did not.
restore_golden adopted
PRIOR_SHA="$(manifest_get '.applied_revision')"
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
TARGET_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
# Make the manifest commit's temporary name unusable, so the transaction fails
# at its very last step with every managed write already done.
mkdir -p "$HOMEDIR/$STATE_DIR_REL/state.json.afk-tmp"
run_afk update --json
assert_eq "F2 the commit failure rolls back"        "$(jget '.operation.result')" "ROLLED_BACK"
assert_eq "F2 nothing was committed"                "$(jget '.operation.applied_state_committed')" "false"
assert_eq "F2 applied_revision names what this host actually carries" \
  "$(jget '.operation.applied_revision')" "$PRIOR_SHA"
assert_eq "F2 and not the revision it was attempting" \
  "$(jget '.operation.applied_revision')" "$(jget '.operation.prior_revision')"
assert_eq "F2 the attempted revision is reported separately" \
  "$(jget '.operation.target_revision')" "$TARGET_SHA"
assert_eq "F2 the durable manifest never moved" "$(manifest_get '.applied_revision')" "$PRIOR_SHA"
rmdir "$HOMEDIR/$STATE_DIR_REL/state.json.afk-tmp" 2>/dev/null

# --- F3: a revision this lifecycle cannot record refuses before mutating ----
#
# The reported failure: the 40-hex applied_revision shape was enforced only at
# the post-write verification gate, so a sha256 checkout took the lock, made
# backups, opened a journal, ran the whole transaction and then failed with
# VERIFICATION_FAILED — a diagnosis that says nothing about the real cause.
new_scenario f3revshape
if git init -q --object-format=sha256 "$SC/sha256co" >/dev/null 2>&1; then
  rm -rf "$SC/sha256co"
  CHECKOUT="$SC/sha256co"
  mkdir -p "$CHECKOUT"
  GIT_DEFAULT_HASH=sha256 git init -q --object-format=sha256 "$CHECKOUT" >/dev/null 2>&1
  # Rebuild the canonical content inside the sha256 repository.
  mkdir -p "$CHECKOUT/adapters" "$CHECKOUT/bin" "$CHECKOUT/lib" "$CHECKOUT/lifecycle" "$CHECKOUT/files/model-router/scripts" \
           "$CHECKOUT/files/humanizer/skills/humanizer"
  cat > "$CHECKOUT/lifecycle/kit.json" <<'JSON'
{
  "kit_id": "agent-flow-kit",
  "lifecycle_schema_version": "1.0",
  "state_schema_version": "1.0",
  "result_schema_version": "1.0",
  "default_branch": "master",
  "managed_inputs": ["adapters", "bin", "lib", "files", "lifecycle"]
}
JSON
  printf 'model-router skill v1\n' > "$CHECKOUT/files/model-router/SKILL.md"
  printf 'dispatch v1\n' > "$CHECKOUT/files/model-router/scripts/dispatch.sh"
  printf 'launcher:\n  router_endpoint: https://canonical.invalid\n' \
    > "$CHECKOUT/files/model-router/subscriptions.yaml"
  printf 'humanizer v1\n' > "$CHECKOUT/files/humanizer/SKILL.md"
  printf 'humanizer inner skill v1\n' > "$CHECKOUT/files/humanizer/skills/humanizer/SKILL.md"
  printf 'policy line one\npolicy line two\n' > "$CHECKOUT/files/claude-global-CLAUDE.md"
  printf 'codex guidance v1\n' > "$CHECKOUT/files/codex-AGENTS.md"
  printf 'runtime adapter v1\n' > "$CHECKOUT/adapters/README"
  printf 'runtime executable v1\n' > "$CHECKOUT/bin/agent-flow-kit"
  printf 'runtime library v1\n' > "$CHECKOUT/lib/afk-common.sh"
  printf '{"schema":"test-release-policy/1"}\n' > "$CHECKOUT/lifecycle/release-policy.json"
  git -C "$CHECKOUT" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
  git_commit_all "$CHECKOUT" "canonical v1"
  HEAD_LEN="$(git -C "$CHECKOUT" rev-parse HEAD | tr -d '\n' | wc -c | tr -d ' ')"
  assert_eq "F3 the fixture really is a non-40-hex checkout" "$HEAD_LEN" "64"
  install_kit "$HOMEDIR" "$CHECKOUT"
  run_afk adopt --json
  assert_eq "F3 the refusal names the revision format" \
    "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[].reason] | index("SOURCE_REVISION_FORMAT_UNSUPPORTED") != null')" "true"
  assert_eq "F3 and refuses as a source problem" "$(jget '.operation.result')" "REFUSED"
  assert_eq "F3 with no mutation attempted" "$(jget '.operation.mutation_performed')" "false"
  assert_no_file "F3 no lock was taken"    "$(lock_path)"
  assert_no_file "F3 no journal was opened" "$(journal_path)"
  assert_no_file "F3 no backup was created" "$HOMEDIR/$STATE_DIR_REL/backups"
  assert_no_file "F3 and no manifest exists" "$(manifest_path)"
else
  skip "F3 revision-format refusal (this git cannot create sha256 repositories)"
fi

# --- F4: a managed write does not widen a mode the owner set ---------------
#
# The reported failure: the section writer built its temporary through shell
# redirection (so it carried the process umask) and renamed it over the
# destination, turning a deliberately 0600 ~/.claude/CLAUDE.md into 0664 while
# the byte-level preservation proof saw nothing wrong.
restore_golden adopted
chmod 600 "$HOMEDIR/.claude/CLAUDE.md"
chmod 600 "$HOMEDIR/.codex/AGENTS.md"
OUTSIDE_BEFORE_F4="$(outside_id "$HOMEDIR/.claude/CLAUDE.md" claude-global-policy)"
CLAUDE_OWNER_BEFORE="$(ls -ldn "$HOMEDIR/.claude/CLAUDE.md" | awk '{print $3, $4}')"
printf 'policy line one\npolicy line two\npolicy line three\n' \
  > "$CHECKOUT/files/claude-global-CLAUDE.md"
printf 'codex guidance v2\n' > "$CHECKOUT/files/codex-AGENTS.md"
git_commit_all "$CHECKOUT" "canonical v2"
run_afk update --json
assert_eq "F4 the convergence succeeds" "$(jget '.operation.result')" "CONVERGED"
assert_eq "F4 a 0600 managed-section host file is still 0600" \
  "$(stat -c '%a' "$HOMEDIR/.claude/CLAUDE.md")" "600"
assert_eq "F4 a 0600 managed copy file is still 0600" \
  "$(stat -c '%a' "$HOMEDIR/.codex/AGENTS.md")" "600"
assert_eq "F4 and the owner is unchanged" \
  "$(ls -ldn "$HOMEDIR/.claude/CLAUDE.md" | awk '{print $3, $4}')" "$CLAUDE_OWNER_BEFORE"
assert_eq "F4 the bytes outside the section are still exactly the owner's" \
  "$(outside_id "$HOMEDIR/.claude/CLAUDE.md" claude-global-policy)" "$OUTSIDE_BEFORE_F4"
# Kit state is not user content and is not created group-readable.
assert_eq "F4 the state manifest is private to its owner" \
  "$(stat -c '%a' "$(manifest_path)")" "600"
assert_eq "F4 and so is the recovery journal" \
  "$(stat -c '%a' "$(journal_path)")" "600"

# --- F5: the plan and its binding describe ONE observation ------------------
#
# The reported failure: afk_plan_binding_compute walked the component table
# calling afk_observe_component, and afk_plan_compute then walked it again
# calling it a second time. Two filesystem passes, so a change landing between
# them produced a plan whose expected_destination_identity disagreed with the
# binding's observed_identity — and revalidation compares binding to binding,
# so it structurally could not see the divergence.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
run_afk update --plan --json
assert_eq "F5 the plan covers every declared component" \
  "$(printf '%s' "$RUN_OUT" | jq -r '.extra.plan.components | length')" \
  "$(printf '%s' "$RUN_OUT" | jq -r '.extra.plan.binding.components | length')"
assert_eq "F5 every component's plan entry and binding entry agree on the identity observed" \
  "$(printf '%s' "$RUN_OUT" | jq -r '
     [ .extra.plan.binding.components[] as $b
       | (.extra.plan.components[] | select(.component == $b.component)) as $p
       | select($p.expected_destination_identity != $b.observed_identity)
       | $b.component ] | join(",")')" ""
assert_eq "F5 and on the containment observation" \
  "$(printf '%s' "$RUN_OUT" | jq -r '
     [ .extra.plan.binding.components[] | select(.containment_escape != null) | .component ] | join(",")')" ""

# --- F6: a lock left by a killed process is diagnosable and reclaimable -----
#
# The reported failure: the lock was an empty directory with no owner record,
# no staleness test and no documented way out. A SIGKILL, an OOM kill or a
# power loss bricked the installation for the lifecycle, and the published
# guidance was "wait for the operation in progress to finish" — advice that
# could never come true.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"

# A provably dead owner: this host, this boot, a pid that no longer exists.
mkdir -p "$(lock_path)"
DEAD_PID="$(bash -c 'echo $$')"
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID + 1)); done
HOST_ID="$(lib_identity host)"
BOOT_ID="$(lib_identity boot)"
assert_ne "F6 this host can identify itself" "$HOST_ID" ""
assert_ne "F6 and can identify this boot"    "$BOOT_ID" ""
jq -n --arg v "$(lib_lock_schema)" --arg h "$HOST_ID" --arg b "$BOOT_ID" \
  --arg p "$DEAD_PID" --arg inc "$(lib_incarnation)" \
  '{lock_schema_version: $v, host_identity: $h, boot_identity: $b,
    pid: ($p | tonumber), process_start_identity: "starttime:1",
    incarnation: $inc, complete: true}' \
  > "$(lock_path)/owner.json"
run_afk update --json
assert_eq "F6 a provably dead owner does not block forever" \
  "$(jget '.operation.result')" "CONVERGED"
assert_eq "F6 and the reclamation is reported rather than silent" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[].reason] | index("OPERATION_LOCK_RECLAIMED") != null')" "true"

# An exact live owner still blocks: THIS process holds it.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
write_live_lock
FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"
run_afk update --json
assert_eq "F6 an exact live owner blocks" \
  "$(jget '.operation.reason')" "CONCURRENT_OPERATION_IN_PROGRESS"
assert_eq "F6 and nothing was written" "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"
rm -rf "$(lock_path)"

# An owner that cannot be judged is neither waited on nor reclaimed.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
mkdir -p "$(lock_path)"
FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"
run_afk update --json
assert_eq "F6 a lock with no owner record fails closed with its own reason" \
  "$(jget '.operation.reason')" "OPERATION_LOCK_OWNER_UNVERIFIABLE"
assert_eq "F6 the guidance names the lock the owner must remove" \
  "$(printf '%s' "$RUN_OUT" | jq -r --arg l "$(lock_path)" \
     '[.findings[] | select(.reason == "OPERATION_LOCK_OWNER_UNVERIFIABLE")
       | .evidence.observed] | join("") | contains($l)')" "true"
assert_eq "F6 and nothing was written" "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"

# A lock taken on another host is foreign, not reclaimable.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
mkdir -p "$(lock_path)"
jq -n --arg v "$(lib_lock_schema)" --arg b "$BOOT_ID" --arg inc "$(lib_incarnation)" \
  '{lock_schema_version: $v, host_identity: "some-other-machine/abc",
    boot_identity: $b, pid: 1, process_start_identity: "starttime:1",
    incarnation: $inc, complete: true}' \
  > "$(lock_path)/owner.json"
run_afk update --json
assert_eq "F6 a lock from another host fails closed" \
  "$(jget '.operation.reason')" "OPERATION_LOCK_OWNER_UNVERIFIABLE"

# --- F6 under concurrency: whole commands, released together ---------------
#
# The unit gate for the lock protocol is tests/lifecycle-concurrency-tests.sh.
# What is proven HERE is the property at the command level: several real
# `agent-flow-kit update` processes, started against one installation carrying
# one abandoned lock and released at the same instant, mutate it at most once
# and leave nothing behind. A lock that is single-winner in isolation is worth
# nothing if the transaction around it is not.

# Release every contender at the same instant: each announces itself and then
# spins on the go file, so the rendezvous is real rather than a long sleep.
contend_update() { # <n>
  local n="$1" i bar out
  bar="$SC/barrier"; out="$SC/contend"
  mkdir -p "$bar" "$out"
  for i in $(seq 1 "$n"); do
    (
      : > "$bar/ready.$i"
      local spins=0
      while [[ ! -e "$bar/go" ]]; do
        spins=$((spins + 1)); (( spins < 60000000 )) || break
      done
      HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
        bash "$AFK" update --json > "$out/$i" 2>/dev/null
    ) &
  done
  local waited=0
  while (( $(find "$bar" -mindepth 1 -maxdepth 1 -name 'ready.*' | wc -l) < n )); do
    waited=$((waited + 1)); (( waited < 60000000 )) || break
  done
  : > "$bar/go"
  wait
  CONTEND_DIR="$out"
}

count_results() { # <n> <result>
  local n="$1" want="$2" i c=0
  for i in $(seq 1 "$n"); do
    [[ "$(jq -r '.operation.result // ""' "$CONTEND_DIR/$i" 2>/dev/null)" == "$want" ]] && c=$((c + 1))
  done
  printf '%s' "$c"
}
count_reason() { # <n> <reason>
  local n="$1" want="$2" i c=0
  for i in $(seq 1 "$n"); do
    [[ "$(jq -r --arg r "$want" '[.findings[]?.reason] | index($r) != null' \
          "$CONTEND_DIR/$i" 2>/dev/null)" == "true" ]] && c=$((c + 1))
  done
  printf '%s' "$c"
}
unexpected_results() { # <n> — results outside the set a contender may report
  local n="$1" i r acc=""
  for i in $(seq 1 "$n"); do
    r="$(jq -r '.operation.result // "NO_JSON"' "$CONTEND_DIR/$i" 2>/dev/null)"
    case "$r" in CONVERGED|NO_CHANGE|REFUSED) : ;; *) acc="$acc $i:$r" ;; esac
  done
  printf '%s' "$acc"
}
# Anything a reclamation or a release should have taken with it. Named by glob
# rather than by listing, so a name with a newline in it cannot hide.
lock_residue() {
  local base="$HOMEDIR/$STATE_DIR_REL" pat acc=""
  for pat in "$base"/lock.stale.* "$base"/lock.released.* "$base"/.afk-reclaim.*; do
    [[ -e "$pat" ]] || continue
    acc="$acc $(basename -- "$pat")"
  done
  printf '%s' "${acc# }"
}

restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
STRANDED="$(strand_lock)"
assert_ne "F6 an abandoned lock could be stranded by the library itself" "$STRANDED" ""
contend_update 2
assert_eq "F6 two updates racing one abandoned lock: exactly one mutates" \
  "$(count_results 2 CONVERGED)" "1"
assert_eq "F6 and no contender reports anything outside the lock's vocabulary" \
  "$(unexpected_results 2)" ""
assert_eq "F6 and the one abandoned lock is reclaimed exactly once" \
  "$(count_reason 2 OPERATION_LOCK_RECLAIMED)" "1"
assert_eq "F6 the destination carries the new revision afterwards" \
  "$(cat "$HOMEDIR/.agents/skills/model-router/SKILL.md")" "model-router skill v2"
assert_no_file "F6 no lock survives the race" "$(lock_path)"
assert_eq "F6 and no reclamation residue survives it either" "$(lock_residue)" ""
run_afk verify --json
assert_eq "F6 the installation the race left behind verifies" \
  "$(jget '.extra.verification.verified')" "true"
assert_eq "F6 and offline verification exits 0" "$RUN_RC" "0"

restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
STRANDED="$(strand_lock)"
contend_update 4
assert_eq "F6 four updates racing one abandoned lock: exactly one mutates" \
  "$(count_results 4 CONVERGED)" "1"
assert_eq "F6 and no contender reports anything outside the lock's vocabulary" \
  "$(unexpected_results 4)" ""
assert_eq "F6 the abandoned lock is still reclaimed exactly once" \
  "$(count_reason 4 OPERATION_LOCK_RECLAIMED)" "1"
assert_no_file "F6 no lock survives the crowd" "$(lock_path)"
assert_eq "F6 and no reclamation residue survives the crowd" "$(lock_residue)" ""
run_afk verify --json
assert_eq "F6 the installation the crowd left behind verifies" \
  "$(jget '.extra.verification.verified')" "true"
assert_eq "F6 and offline verification exits 0" "$RUN_RC" "0"

# The same crowd against a lock held by an owner that is ALIVE: nobody may
# mutate, and the installation must be byte-identical afterwards.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
write_live_lock
FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"
contend_update 3
assert_eq "F6 a live owner blocks every contender" "$(count_results 3 CONVERGED)" "0"
assert_eq "F6 and each of them says why"           "$(count_reason 3 CONCURRENT_OPERATION_IN_PROGRESS)" "3"
assert_eq "F6 nothing was written while it was held" \
  "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"
assert_file "F6 and the live owner's lock is still there" "$(lock_path)/owner.json"
rm -rf "$(lock_path)"

# The publication window at the command level. Taking the lock is two steps,
# and a contender that observes the gap between them used to be refused with
# OPERATION_LOCK_OWNER_UNVERIFIABLE -- whose owner action is "remove the lock
# by hand". Following that while the winner mutates is the two-owners state
# the lock exists to prevent, so the guidance an ordinary loser reads is a
# safety property, not a nicety.
#
# The window is held open deliberately here rather than raced for: a live
# process creates the directory and publishes the record only when this test
# says so, with the real `agent-flow-kit update` contending in between.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"

FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"
JF_BEFORE="$(journal_fingerprint)"

WINDOW="$SC/window"; PUBLISH="$SC/publish"; LETGO="$SC/letgo"
hold_publication_window "$WINDOW" "$PUBLISH" "$LETGO"
SPIN=0; while [[ ! -e "$WINDOW" ]]; do SPIN=$((SPIN + 1)); (( SPIN < 60000000 )) || break; done
assert_file "F6 a winner can be held between mkdir and the owner record" "$(lock_path)"
assert_no_file "F6 with the lock carrying no record yet" "$(lock_path)/owner.json"

UPD_OUT="$SC/window-update.json"
( HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
    bash "$AFK" update --json > "$UPD_OUT" 2>/dev/null ) &
UPD_PID=$!
CONTENDER_PAUSED="false"
wait_until_contender_pauses "$UPD_PID" && CONTENDER_PAUSED="true"
UPD_STILL_WAITING="false"
kill -0 "$UPD_PID" 2>/dev/null && UPD_STILL_WAITING="true"
: > "$PUBLISH"
wait "$UPD_PID"
: > "$LETGO"
wait "$PUBLISHER_PID" 2>/dev/null || true

assert_eq "F6 a contender inside the window is observed waiting, not refusing" \
  "$CONTENDER_PAUSED" "true"
assert_eq "F6 and it is still there when the winner finally publishes" \
  "$UPD_STILL_WAITING" "true"
assert_eq "F6 and then refuses for the owner it actually found" \
  "$(jq -r '.operation.reason // ""' "$UPD_OUT" 2>/dev/null)" "CONCURRENT_OPERATION_IN_PROGRESS"
assert_eq "F6 never for a lock it could not judge" \
  "$(jq -r '[.findings[]?.reason] | index("OPERATION_LOCK_OWNER_UNVERIFIABLE") != null' \
     "$UPD_OUT" 2>/dev/null)" "false"
assert_eq "F6 so no contender is ever told to remove a lock a live owner holds" \
  "$(jq -r '.next_safe_action // "" | contains("remove")' "$UPD_OUT" 2>/dev/null)" "false"
assert_eq "F6 and it is told to wait for the operation instead" \
  "$(jq -r '.next_safe_action // "" | contains("Wait for the operation")' "$UPD_OUT" 2>/dev/null)" "true"
assert_eq "F6 and the winner's lock still carries the incarnation it published" \
  "$(jq -r '.incarnation // ""' "$(lock_path)/owner.json" 2>/dev/null)" "$(cat "$WINDOW.inc" 2>/dev/null)"
# The winner's lock is the only thing this scenario added; with it taken back
# out, anything left over is something the refused contender wrote.
rm -rf "$(lock_path)"
assert_eq "F6 nothing was written while the window was open" \
  "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"
assert_eq "F6 and the refused contender opened no journal" \
  "$(journal_fingerprint)" "$JF_BEFORE"

# The ordinary case no gate constructed: several real updates released onto an
# installation with NO pre-existing lock. Every loser observes the winner's
# publication window, so the wrong refusal shows up here without any fixture
# holding anything open.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
assert_no_file "F6 the clean-path race starts with no lock at all" "$(lock_path)"
contend_update 8
assert_eq "F6 eight updates racing a clean lock path: exactly one mutates" \
  "$(count_results 8 CONVERGED)" "1"
assert_eq "F6 and not one of them is told the lock has no owner" \
  "$(count_reason 8 OPERATION_LOCK_OWNER_UNVERIFIABLE)" "0"
assert_eq "F6 nor that the lock could not be established" \
  "$(count_reason 8 OPERATION_LOCK_UNAVAILABLE)" "0"
assert_eq "F6 and no contender reports anything outside the lock's vocabulary" \
  "$(unexpected_results 8)" ""
assert_eq "F6 nothing was reclaimed: there was nothing abandoned to reclaim" \
  "$(count_reason 8 OPERATION_LOCK_RECLAIMED)" "0"
assert_eq "F6 the destination carries the new revision afterwards" \
  "$(cat "$HOMEDIR/.agents/skills/model-router/SKILL.md")" "model-router skill v2"
assert_no_file "F6 no lock survives the clean-path race" "$(lock_path)"
assert_eq "F6 and no residue survives it either" "$(lock_residue)" ""
run_afk verify --json
assert_eq "F6 the installation the clean-path race left behind verifies" \
  "$(jget '.extra.verification.verified')" "true"

# The neighbouring instant at the command level: the lock's owner record is
# released between the moment the judge finds it and the moment it reads it. A
# read of a file that is gone yields nothing, which is byte for byte what a
# record that could not be parsed yields -- and "could not be parsed" used to
# be refused at once with OPERATION_LOCK_OWNER_UNVERIFIABLE and "remove the
# lock by hand", for a lock that had just been legitimately handed over. A
# record is installed by renaming one complete temporary file onto its name, so
# a partial record is never observable and this state can only mean the record
# was not there.
#
# The recovery path is used deliberately: an interrupted journal takes the lock
# WITHOUT the pre-flight judgement the ordinary mutation path makes first, so
# the first read of the owner record in the whole command is the acquisition's
# own. That read is a fork, so a reader ahead of the real one on PATH does the
# rename-and-remove a release does, once, and hands over to the real reader,
# which finds nothing. The hook is installed under BOTH names a judge could
# read a record with, so the fixture pins the VERDICT rather than which tool
# produced it. No lifecycle code is replaced; only the instant the release
# lands is the fixture's, and the read count below pins that it landed on the
# read the acquisition made.
restore_golden adopted
VANISH_SAFE_SHA="$(manifest_get '.applied_revision')"
VANISH_CODEX_GOOD="$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")"
VANISH_BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-vanish"
mkdir -p "$VANISH_BACKUPS"
cp "$HOMEDIR/.codex/AGENTS.md" "$VANISH_BACKUPS/codex-global-guidance"
VANISH_PRE="$(file_id "$HOMEDIR/.codex/AGENTS.md")"
printf 'half applied content\n' > "$HOMEDIR/.codex/AGENTS.md"
write_journal "$VANISH_BACKUPS" codex-global-guidance REPLACE \
  "$HOMEDIR/.codex/AGENTS.md" "$VANISH_PRE"
VANISH_INC="$(strand_lock)"
assert_ne "F6 an abandoned lock could be stranded by the library itself" "$VANISH_INC" ""
assert_eq "F6 carrying a record the library wrote and jq can read" \
  "$(jq -r '.complete' "$(lock_path)/owner.json" 2>/dev/null)" "true"

VANISH_BIN="$SC/vanishbin"; mkdir -p "$VANISH_BIN"
cat > "$VANISH_BIN/jq" <<'SHIM'
#!/usr/bin/env bash
# Not a reader: a moment. On the FIRST read of exactly the record under test,
# the lock is released -- renamed aside and removed, the way afk_lock_release
# does it -- and then the real reader is run against a name that no longer
# exists.
case "${0##*/}" in
  jq)  real="$AFK_TEST_REAL_JQ" ;;
  cat) real="$AFK_TEST_REAL_CAT" ;;
  *)   printf 'fixture: unknown reader %s\n' "${0##*/}" >&2; exit 97 ;;
esac
[[ "$real" != "${BASH_SOURCE[0]}" ]] || { printf 'fixture reader recursion\n' >&2; exit 97; }
if [[ -n "${AFK_TEST_VANISH_REC:-}" && "${*: -1}" == "$AFK_TEST_VANISH_REC" &&
      ! -e "$AFK_TEST_VANISH_LOG" ]]; then
  printf 'released\n' >> "$AFK_TEST_VANISH_LOG"
  mv -- "$AFK_TEST_VANISH_LOCK" "$AFK_TEST_VANISH_LOCK.handover" 2>/dev/null
  rm -rf -- "$AFK_TEST_VANISH_LOCK.handover" 2>/dev/null
fi
exec "$real" "$@"
SHIM
cp "$VANISH_BIN/jq" "$VANISH_BIN/cat"
chmod 755 "$VANISH_BIN/jq" "$VANISH_BIN/cat"

# Resolved BEFORE the shim reaches PATH: a prefix assignment list is applied
# left to right, so a `command -v jq` written after PATH= would find the shim
# and the shim would exec itself forever.
VANISH_REAL_JQ="$(command -v jq)"
VANISH_REAL_CAT="$(command -v cat)"
assert_ne "F6 there is a real jq for the fixture to hand over to"  "$VANISH_REAL_JQ"  ""
assert_ne "F6 there is a real cat for the fixture to hand over to" "$VANISH_REAL_CAT" ""
VANISH_OUT="$SC/vanish-update.json"
HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
  PATH="$VANISH_BIN:$PATH" \
  AFK_TEST_REAL_JQ="$VANISH_REAL_JQ" \
  AFK_TEST_REAL_CAT="$VANISH_REAL_CAT" \
  AFK_TEST_VANISH_REC="$(lock_path)/owner.json" \
  AFK_TEST_VANISH_LOCK="$(lock_path)" \
  AFK_TEST_VANISH_LOG="$SC/released" \
  bash "$AFK" update --json > "$VANISH_OUT" 2>/dev/null
VANISH_RC=$?

assert_eq "F6 the release landed on the one read of the record this path makes" \
  "$(wc -l < "$SC/released" 2>/dev/null || printf 0)" "1"
assert_eq "F6 a record that is not there is not a record that could not be parsed" \
  "$(jq -r '[.findings[]?.reason] | index("OPERATION_LOCK_OWNER_UNVERIFIABLE") != null' \
     "$VANISH_OUT" 2>/dev/null)" "false"
assert_eq "F6 so nobody is told to remove a lock that was just handed over" \
  "$(jq -r '.next_safe_action // "" | contains("remove")' "$VANISH_OUT" 2>/dev/null)" "false"
assert_eq "F6 the work the lock was guarding happens instead" \
  "$(jq -r '.operation.result // ""' "$VANISH_OUT" 2>/dev/null)" "RECOVERED"
assert_eq "F6 which is the deterministic not-ready exit" "$VANISH_RC" "3"
assert_eq "F6 the interrupted destination is back at its pre-operation content" \
  "$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")" "$VANISH_CODEX_GOOD"
assert_eq "F6 the journal is closed" "$(jq -r '.state' "$(journal_path)")" "COMMITTED"
assert_eq "F6 the applied revision never moved" \
  "$(manifest_get '.applied_revision')" "$VANISH_SAFE_SHA"
assert_no_file "F6 no lock survives it" "$(lock_path)"
assert_eq "F6 and no residue survives it either" "$(lock_residue)" ""

# The reclamation that loses the take it earned. A reclaimer wins the
# arbitration marker, proves the abandoned incarnation, renames the lock
# directory aside and removes it -- and only then tries to take the empty path
# it created. That mkdir can be lost. It used to be reported as though the
# reclamation had never happened: OPERATION_LOCK_RECLAIMED was set by the
# ACQUISITION on success, so a reclaimer that lost the race destroyed another
# process's lock and said nothing, and the contender that took the freed path
# had reclaimed nothing and said nothing either. "Reclaiming a lock is never
# silent" was false exactly when it mattered.
#
# The window is forced from outside with no in-process interception: between
# the rename and the mkdir the library reads the aside record with `jq`, and
# that path -- lock.stale.<incarnation>/owner.json -- exists only in that
# window. A `jq` ahead of the real one takes the lock path there, once, and
# hands over.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
SILENT_SAFE_SHA="$(manifest_get '.applied_revision')"
SILENT_INC="$(strand_lock)"
assert_ne "F6 an abandoned lock could be stranded by the library itself" "$SILENT_INC" ""

SILENT_BIN="$SC/silentbin"; mkdir -p "$SILENT_BIN"
cat > "$SILENT_BIN/jq" <<'SHIM'
#!/usr/bin/env bash
# The aside record is read exactly once, in the window between the abandoned
# lock being renamed out of the way and the reclaimer's own mkdir. A contender
# takes the lock path there -- for real, with the same mkdir the library uses.
[[ "$AFK_TEST_REAL_JQ" != "${BASH_SOURCE[0]}" ]] || { printf 'recursion\n' >&2; exit 97; }
if [[ -n "${AFK_TEST_ASIDE_GLOB:-}" && "${*: -1}" == $AFK_TEST_ASIDE_GLOB &&
      ! -e "$AFK_TEST_STOLEN" ]]; then
  if mkdir -- "$AFK_TEST_LOCK" 2>/dev/null; then printf 'stolen' > "$AFK_TEST_STOLEN"; fi
fi
exec "$AFK_TEST_REAL_JQ" "$@"
SHIM
chmod 755 "$SILENT_BIN/jq"
SILENT_REAL_JQ="$(command -v jq)"
assert_ne "F6 there is a real jq for the fixture to hand over to" "$SILENT_REAL_JQ" ""
SILENT_OUT="$SC/silent-update.json"
HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
  PATH="$SILENT_BIN:$PATH" \
  AFK_TEST_REAL_JQ="$SILENT_REAL_JQ" \
  AFK_TEST_ASIDE_GLOB="$(lock_path).stale.*/owner.json" \
  AFK_TEST_LOCK="$(lock_path)" \
  AFK_TEST_STOLEN="$SC/stolen" \
  bash "$AFK" update --json > "$SILENT_OUT" 2>/dev/null
SILENT_RC=$?

assert_eq "F6 a contender really did take the lock path the reclaimer freed" \
  "$(cat "$SC/stolen" 2>/dev/null || printf 'no')" "stolen"
assert_no_file "F6 and the abandoned incarnation's record was destroyed" \
  "$(lock_path)/owner.json"
assert_eq "F6 a reclamation that lost the take is still reported" \
  "$(jq -r '[.findings[]?.reason] | index("OPERATION_LOCK_RECLAIMED") != null' \
     "$SILENT_OUT" 2>/dev/null)" "true"
assert_eq "F6 exactly once, for the one abandoned lock it destroyed" \
  "$(jq -r '[.findings[]?.reason | select(. == "OPERATION_LOCK_RECLAIMED")] | length' \
     "$SILENT_OUT" 2>/dev/null)" "1"
# The reclamation's own words ride in `evidence.observed`, which is where every
# afk_mutation_finding puts the detail it is handed.
SILENT_DETAIL="$(jq -r '[.findings[]? | select(.reason == "OPERATION_LOCK_RECLAIMED") | .evidence.observed][0] // ""' \
  "$SILENT_OUT" 2>/dev/null)"
assert_ne "F6 the reclamation report says what it destroyed" "$SILENT_DETAIL" ""
assert_contains "F6 naming the owner it proved was gone" "$SILENT_DETAIL" "pid "
assert_eq "F6 the run that reclaimed it still refuses, having never held the lock" \
  "$(jq -r '.operation.result // ""' "$SILENT_OUT" 2>/dev/null)" "REFUSED"
assert_eq "F6 and refuses for the lock it could not judge, not for a lock it took" \
  "$(jq -r '.operation.reason // ""' "$SILENT_OUT" 2>/dev/null)" \
  "OPERATION_LOCK_OWNER_UNVERIFIABLE"
assert_eq "F6 which is the owner-action exit" "$SILENT_RC" "2"
assert_eq "F6 the applied revision never moved" \
  "$(manifest_get '.applied_revision')" "$SILENT_SAFE_SHA"
assert_eq "F6 and no reclamation residue survives it" "$(lock_residue)" ""
rm -rf -- "$(lock_path)"

# The arbitration marker the winner's rename carried away, through the real
# command. A losing reclaimer's marker lives INSIDE the lock directory, so the
# winner's rename takes it with it: between the loser's claim and the judge
# that reads that marker, the marker can simply stop existing. That instant
# used to be refused as "a reclamation of this lock was started by a process
# that cannot be judged" -- OPERATION_LOCK_OWNER_UNVERIFIABLE and "remove the
# lock by hand" -- for a lock that had just been legitimately handed over.
#
# The marker's judge READS the marker, and that read is a fork, so the handover
# is landed from outside with no in-process interception at all: a reader ahead
# of the real one on PATH does exactly what the winner does -- renames the lock
# directory away and removes it -- on the one read of exactly that marker.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
MV_INC="$(strand_lock)"
assert_ne "F6 an abandoned lock could be stranded by the library itself" "$MV_INC" ""
# Another reclaimer owns the marker for that exact incarnation, so the run
# below must LOSE the claim and go on to judge what it lost to.
HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" bash -c '
  . "$1/lib/afk-common.sh"; . "$1/lib/afk-source.sh"; . "$1/lib/afk-inventory.sh"
  . "$1/lib/afk-commands.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
  AFK_STATE_DIR="$2"; AFK_LOCK_DIR="$2/lock"
  afk_lock_marker_claim "$AFK_LOCK_DIR/reclaim.$3.json" >/dev/null 2>&1
' _ "$KIT_ROOT" "$HOMEDIR/$STATE_DIR_REL" "$MV_INC"
assert_file "F6 so a later arrival must lose the claim" \
  "$(lock_path)/reclaim.$MV_INC.json"

MV_BIN="$SC/markerbin"; mkdir -p "$MV_BIN"
cat > "$MV_BIN/jq" <<'SHIM'
#!/usr/bin/env bash
# Not a reader: a moment. On the ONE read of exactly the marker under test, the
# whole lock directory is carried away -- which is what the winning reclaimer's
# rename does, and it takes the marker inside it with it.
case "${0##*/}" in
  jq)  real="$AFK_TEST_REAL_JQ" ;;
  cat) real="$AFK_TEST_REAL_CAT" ;;
  *)   printf 'fixture: unknown reader %s\n' "${0##*/}" >&2; exit 97 ;;
esac
[[ "$real" != "${BASH_SOURCE[0]}" ]] || { printf 'fixture reader recursion\n' >&2; exit 97; }
if [[ -n "${AFK_TEST_MARKER:-}" && "${*: -1}" == "$AFK_TEST_MARKER" && ! -e "$AFK_TEST_FIRED" ]]; then
  printf 'carried\n' >> "$AFK_TEST_FIRED"
  mv -- "$AFK_TEST_LOCK" "$AFK_TEST_LOCK.handover" 2>/dev/null
  rm -rf -- "$AFK_TEST_LOCK.handover" 2>/dev/null
fi
exec "$real" "$@"
SHIM
cp "$MV_BIN/jq" "$MV_BIN/cat"
chmod 755 "$MV_BIN/jq" "$MV_BIN/cat"
MV_REAL_JQ="$(command -v jq)"; MV_REAL_CAT="$(command -v cat)"
MV_OUT="$SC/marker-update.json"
HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
  PATH="$MV_BIN:$PATH" \
  AFK_TEST_REAL_JQ="$MV_REAL_JQ" AFK_TEST_REAL_CAT="$MV_REAL_CAT" \
  AFK_TEST_MARKER="$(lock_path)/reclaim.$MV_INC.json" \
  AFK_TEST_LOCK="$(lock_path)" \
  AFK_TEST_FIRED="$SC/carried" \
  bash "$AFK" update --json > "$MV_OUT" 2>/dev/null
MV_RC=$?

assert_eq "F6 the handover landed on the one read of the marker this path makes" \
  "$(wc -l < "$SC/carried" 2>/dev/null || printf 0)" "1"
assert_eq "F6 a marker carried off by the winner is not a reclaimer that cannot be judged" \
  "$(jq -r '[.findings[]?.reason] | index("OPERATION_LOCK_OWNER_UNVERIFIABLE") != null' \
     "$MV_OUT" 2>/dev/null)" "false"
assert_eq "F6 so nobody is told to remove a lock that was just handed over" \
  "$(jq -r '.next_safe_action // "" | contains("remove")' "$MV_OUT" 2>/dev/null)" "false"
assert_eq "F6 the work the lock was guarding happens instead" \
  "$(jq -r '.operation.result // ""' "$MV_OUT" 2>/dev/null)" "CONVERGED"
assert_eq "F6 which exits 0" "$MV_RC" "0"
assert_eq "F6 the destination carries the new revision afterwards" \
  "$(cat "$HOMEDIR/.agents/skills/model-router/SKILL.md")" "model-router skill v2"
assert_no_file "F6 no lock survives it" "$(lock_path)"
assert_eq "F6 and no residue survives it either" "$(lock_residue)" ""

# --- F7: journal_state is a bound input that can actually falsify -----------
#
# The reported failure: afk_plan_revalidate re-read the manifest and the
# adaptation records from disk but never re-ran afk_evaluate_journal, so the
# recomputed binding carried the value from the initial evaluation and
# journal_state compared equal to itself by construction — decoration in the
# half of the plan that is supposed to be falsifiable.
restore_golden adopted
UNIT_JOURNAL="$(journal_path)"
JOURNAL_BINDING="$(HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" \
  AFK_KIT_ROOT="$CHECKOUT" bash -c '
    . "$1/lib/afk-common.sh"; . "$1/lib/afk-source.sh"; . "$1/lib/afk-inventory.sh"
    . "$1/lib/afk-commands.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
    AFK_KIT_ROOT="$2"
    AFK_STATE_DIR="$HOME/.local/state/agent-flow-kit"
    AFK_MANIFEST="$AFK_STATE_DIR/state.json"; AFK_JOURNAL="$AFK_STATE_DIR/journal.json"
    AFK_LOCK_DIR="$AFK_STATE_DIR/lock"; AFK_BACKUP_ROOT="$AFK_STATE_DIR/backups"
    AFK_STAGE_ROOT="$AFK_STATE_DIR/stage"
    AFK_SKILLS_HOME="$HOME/.agents/skills"; AFK_CLAUDE_HOME="$HOME/.claude"
    AFK_CODEX_HOME="$HOME/.codex"
    afk_evaluate_installation false false
    afk_plan_compute update >/dev/null 2>&1 || true
    before="$(printf "%s" "$AFK_PLAN_BINDING" | jq -r ".journal_state")"
    # Move the journal underneath the plan, exactly as an interrupted operation
    # elsewhere would, and revalidate at the mutation boundary.
    jq -c ".state = \"IN_PROGRESS\"" "$AFK_JOURNAL" > "$AFK_JOURNAL.x" && mv "$AFK_JOURNAL.x" "$AFK_JOURNAL"
    afk_plan_revalidate >/dev/null 2>&1
    after="$(printf "%s" "$AFK_PLAN_BINDING" | jq -r ".journal_state")"
    printf "%s|%s|%s\n" "$before" "$after" "$AFK_PLAN_STALE_REASON"
  ' _ "$KIT_ROOT" "$CHECKOUT")"
assert_eq "F7 the binding recorded the journal state the plan was computed at" \
  "${JOURNAL_BINDING%%|*}" "COMMITTED"
assert_eq "F7 revalidation re-reads it rather than comparing it to itself" \
  "$(printf '%s' "$JOURNAL_BINDING" | cut -d'|' -f2)" "OPEN"
assert_eq "F7 so a journal that moved makes the plan stale" \
  "$(printf '%s' "$JOURNAL_BINDING" | cut -d'|' -f3)" "PLAN_STALE_MANIFEST_CHANGED"

# --- F8: backups are never orphaned by a crash before the journal ----------
#
# The reported failure: the backup loop created a copy of every REPLACE/INSTALL
# destination and only then wrote the journal, so a kill inside that window
# left copies of user content in the state directory that no journal named and
# nothing ever reclaimed.
restore_golden adopted
ORPHAN="$HOMEDIR/$STATE_DIR_REL/backups/op-orphaned-by-a-crash"
mkdir -p "$ORPHAN"
cp "$HOMEDIR/.codex/AGENTS.md" "$ORPHAN/codex-global-guidance"
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
run_afk update --json
assert_eq "F8 the convergence succeeds"  "$(jget '.operation.result')" "CONVERGED"
assert_no_file "F8 and recovery material no journal names is reclaimed" "$ORPHAN"

# The journal names its backup directory BEFORE that directory is filled, so a
# run killed inside the backup loop leaves a record that can reclaim it.
restore_golden adopted
PREPARED="$HOMEDIR/$STATE_DIR_REL/backups/op-prepared"
mkdir -p "$PREPARED"
cp "$HOMEDIR/.codex/AGENTS.md" "$PREPARED/codex-global-guidance"
jq -n --arg b "$PREPARED" \
  '{journal_schema_version: "2.0", state: "PREPARING", operation_id: "op-prepared",
    command: "update", backup_dir: $b, rollback_state: "NOT_REQUIRED",
    pre_mutation: [], plan: {components: []}, completed_steps: []}' > "$(journal_path)"
run_afk update --json
assert_eq "F8 an operation killed before its first write is recoverable" \
  "$(jget '.operation.result')" "RECOVERED"
assert_eq "F8 and its journal is closed" "$(jq -r '.state' "$(journal_path)")" "COMMITTED"
assert_no_file "F8 with the material it had prepared reclaimed" "$PREPARED"

run_afk schema
SCHEMA_JSON="$RUN_OUT"
schema_vocab() { printf '%s' "$SCHEMA_JSON" | jq -r ".$1[]" | LC_ALL=C sort; }
doc_vocab() { # <key> — the machine-checkable block from the contract document
  awk -v key="$1" 'BEGIN { marker = "<!-- machine-checkable: " key " -->" }
    $0 == marker { inb = 1; next }
    inb && $0 == "<!-- end -->" { inb = 0 }
    inb && $0 !~ /^```/ && $0 != "" { print }
  ' "$CONTRACT_DOC" | LC_ALL=C sort
}
for key in commands plan_actions plan_dispositions operation_results \
           journal_states verification_results reason_codes; do
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

# NOTE for future test authors: in jq, the argument to index() is evaluated
# against index()'s OWN input. `$pub | index(.)` therefore asks whether the
# published array contains ITSELF — which is always true — and `$pub |
# index(.operation.result)` errors with "Cannot index array with string".
# Every membership test below binds the needle to a variable FIRST, and each
# one reports the offending values rather than a count, so a failure names what
# is unpublished instead of only saying that something is.
PUB_REASONS="$(printf '%s' "$SCHEMA_JSON" | jq -c '.reason_codes')"
assert_ne "the update really emitted reason codes to check" \
  "$(printf '%s' "$UPDATE_JSON" | jq -r '[.. | objects | .reason? | select(type == "string")] | length')" "0"
assert_eq "every reason code an update emits is published" \
  "$(printf '%s' "$UPDATE_JSON" | jq -r --argjson pub "$PUB_REASONS" \
     '[.. | objects | .reason? | select(type == "string")
       | . as $code | select(($pub | index($code)) == null)] | unique | join(",")')" ""
PUB_ACTIONS="$(printf '%s' "$SCHEMA_JSON" | jq -c '.plan_actions')"
assert_eq "every plan action is published" \
  "$(printf '%s' "$UPDATE_JSON" | jq -r --argjson pub "$PUB_ACTIONS" \
     '[.extra.plan.components[].action
       | . as $action | select(($pub | index($action)) == null)] | unique | join(",")')" ""
PUB_RESULTS="$(printf '%s' "$SCHEMA_JSON" | jq -c '.operation_results')"
assert_eq "the operation result is published" \
  "$(printf '%s' "$UPDATE_JSON" | jq -r --argjson pub "$PUB_RESULTS" \
     '.operation.result as $result
      | if ($pub | index($result)) == null then $result else "" end')" ""
assert_eq "every finding state is inside the component-state vocabulary" \
  "$(printf '%s' "$UPDATE_JSON" | jq -r --argjson pub "$(printf '%s' "$SCHEMA_JSON" | jq -c '.component_states')" \
     '[.findings[].state | . as $state | select(($pub | index($state)) == null)] | unique | join(",")')" ""

# Human output is projected from the same document, plan and operation included.
restore_golden adopted
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
run_afk update --plan --json
PLAN_JSON="$RUN_OUT"
run_afk update --plan
PLAN_HUMAN="$RUN_OUT"
MISSING=""
while IFS= read -r needle; do
  [[ -n "$needle" ]] || continue
  if [[ "$PLAN_HUMAN" != *"$needle"* ]]; then MISSING="${MISSING}[$needle] "; fi
done < <(printf '%s' "$PLAN_JSON" | jq -r '
  [ .extra.plan.plan_identity, .extra.plan.disposition,
    (.extra.plan.required_mutations | tostring) ]
  + [ .extra.plan.components[] | .component, .action, .destination, .expected_final_state ]
  + [ .extra.plan.components[] | select(.reason != null) | .reason ]
  | map(select(. != null and . != "")) | .[]')
assert_eq "the plan is completely projected into human output" "$MISSING" ""

run_afk update
UPDATE_HUMAN="$RUN_OUT"
run_afk verify --json
VERIFY_JSON="$RUN_OUT"
run_afk verify
VERIFY_HUMAN="$RUN_OUT"
assert_contains "the operation result reaches human output" "$UPDATE_HUMAN" "result=CONVERGED"
assert_contains "with the revisions it moved between" "$UPDATE_HUMAN" "applied_revision="
MISSING=""
while IFS= read -r needle; do
  [[ -n "$needle" ]] || continue
  if [[ "$VERIFY_HUMAN" != *"$needle"* ]]; then MISSING="${MISSING}[$needle] "; fi
done < <(printf '%s' "$VERIFY_JSON" | jq -r '
  [ (.extra.verification.verified | tostring), (.extra.verification.checks_run | tostring) ]
  + [ .extra.verification.checks[] | .subject, .check, .result ]
  | map(select(. != null and . != "")) | .[]')
assert_eq "the verification report is completely projected into human output" "$MISSING" ""

# ===========================================================================
head1 "11. F6-R10 — a signal never frees the lock while this process can write"
# ===========================================================================
# The reported failure: `trap 'afk_lock_release' EXIT INT TERM`. A handler on
# INT or TERM that does not exit RESUMES the script at the point the signal
# landed, so the release ran and the process carried on writing without the
# lock. A second invocation could take the freed path and mutate the same
# installation alongside the first — two owners, one installation, with the
# first one still alive. Every earlier interruption test was about a process
# that DIED holding the lock (the lock survives, and reclamation handles it);
# none of them could see the owner that lives on without it.
#
# The signal is delivered at a point this suite CHOOSES rather than races for.
# A test-only interposer is put on PATH ahead of one tool the transaction
# really calls, and it parks the calling process on the invocation the case is
# about, then becomes the real tool. Nothing in bin/ or lib/ is made
# observable, and the run under test is a real `agent-flow-kit update` writing
# a real installation.
#
# The interposer parks TWICE where a case asks for it: once where the signal is
# delivered, and again on the next call to that tool. The second park is the
# witness that decides this whole section — it can only be reached by a process
# that handled the signal and went back to work, which is the defect itself.

SIGDIR="" SHIMDIR="" VICTIM_PID="" SIG_RC="" SIG_PARKED2=""
SIG_LOCK_AT_PARK2="" SIG_CONTENDER_AT_PARK2=""

# The interposer. `parked.N` says it is stopped there; `go.N` releases it. Both
# are files rather than a duration, so the delivery point is a fact.
sig_make_shim() { # <tool>
  local tool="$1" real
  real="$(command -v "$tool")"
  [[ -n "$real" ]] || { bad "fixture: the real $tool could be found" ""; return 1; }
  {
    printf '#!/usr/bin/env bash\n'
    printf '# generated by tests/lifecycle-mutation-tests.sh — test-only interposer\n'
    printf 'AFK_SIGTEST_REAL=%q\n' "$real"
    cat <<'SHIM'
_afk_park() { # <n>
  local n="$1" i=0
  : > "$AFK_SIGTEST_DIR/parked.$n"
  while [[ ! -e "$AFK_SIGTEST_DIR/go.$n" ]]; do
    i=$((i + 1)); (( i < 18000 )) || break
    sleep 0.01
  done
}
if [[ -n "${AFK_SIGTEST_DIR:-}" && -d "${AFK_SIGTEST_DIR:-}" ]]; then
  if [[ -e "$AFK_SIGTEST_DIR/armed" ]]; then
    if [[ "${AFK_SIGTEST_SECOND:-}" == "true" && ! -e "$AFK_SIGTEST_DIR/parked.2" ]]; then
      _afk_park 2
    fi
  elif [[ -z "${AFK_SIGTEST_MATCH:-}" || "$*" == *"${AFK_SIGTEST_MATCH}"* ]]; then
    : > "$AFK_SIGTEST_DIR/armed"
    _afk_park 1
  fi
fi
exec "$AFK_SIGTEST_REAL" "$@"
SHIM
  } > "$SHIMDIR/$tool"
  chmod 755 "$SHIMDIR/$tool"
}

# Start a real lifecycle command that will park itself. `exec` keeps the pid
# the test signals identical to the pid the lock records as its owner.
sig_launch() { # <tool> <match> <second:true|false> <args...>
  local tool="$1" match="$2" second="$3"
  shift 3
  SIGDIR="$SC/sig"; SHIMDIR="$SC/shim"
  rm -rf "$SIGDIR" "$SHIMDIR"
  mkdir -p "$SIGDIR" "$SHIMDIR"
  sig_make_shim "$tool" || return 1
  ( exec env HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             PATH="$SHIMDIR:$PATH" \
             AFK_SIGTEST_DIR="$SIGDIR" \
             AFK_SIGTEST_MATCH="$match" \
             AFK_SIGTEST_SECOND="$second" \
             bash "$AFK" "$@" ) > "$SIGDIR/out" 2> "$SIGDIR/err" &
  VICTIM_PID=$!
  return 0
}

# Bounded, and it gives up the moment the process it is waiting on is gone. The
# ceiling is three minutes rather than a tight one: this section runs under
# concurrent load in the mandated gate, and a bound a loaded host can reach is a
# flake rather than a bound. Nothing here waits out a correct run — the parks
# are released by the test, and a dead process ends the wait immediately.
sig_wait_parked() { # <n>
  local n="$1" i=0
  while [[ ! -e "$SIGDIR/parked.$n" ]]; do
    kill -0 "$VICTIM_PID" 2>/dev/null || return 1
    i=$((i + 1)); (( i < 18000 )) || return 1
    sleep 0.01
  done
  return 0
}

# Let the parked call finish and wait for whatever the process does next: it
# either reaches the tool again — which only a resumed handler can do — or it
# ends.
#
# Reaching it again is the moment the finding is about, so it is inspected
# rather than merely counted: what does the lock path hold while this process
# is demonstrably still writing, and can a second real `agent-flow-kit update`
# take it? Sets SIG_PARKED2, SIG_LOCK_AT_PARK2, SIG_CONTENDER_AT_PARK2, SIG_RC.
sig_settle() {
  local i=0
  SIG_PARKED2="false"; SIG_LOCK_AT_PARK2="not-reached"
  SIG_CONTENDER_AT_PARK2="not-reached"
  : > "$SIGDIR/go.1"
  while kill -0 "$VICTIM_PID" 2>/dev/null; do
    [[ -e "$SIGDIR/parked.2" ]] && break
    i=$((i + 1)); (( i < 18000 )) || break
    sleep 0.01
  done
  if [[ -e "$SIGDIR/parked.2" ]]; then
    SIG_PARKED2="true"
    if [[ -n "$(lock_incarnation_now)" ]]; then
      SIG_LOCK_AT_PARK2="held"
    else
      SIG_LOCK_AT_PARK2="FREED-WHILE-WRITING"
    fi
    run_afk update --json
    if [[ "$(jget '.operation.reason')" == "CONCURRENT_OPERATION_IN_PROGRESS" ]]; then
      SIG_CONTENDER_AT_PARK2="refused"
    else
      SIG_CONTENDER_AT_PARK2="ACQUIRED-ALONGSIDE-THE-WRITER"
    fi
    : > "$SIGDIR/go.2"
  fi
  wait "$VICTIM_PID"
  SIG_RC=$?
}

lock_incarnation_now() { jq -r '.incarnation // ""' "$(lock_path)/owner.json" 2>/dev/null; }

# A host one revision behind, with both managed trees due to change, so the
# write phase makes more than one call to the interposed tool.
sig_scenario() { # <name>
  restore_golden adopted
  printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
  printf 'humanizer v2\n' > "$CHECKOUT/files/humanizer/SKILL.md"
  git_commit_all "$CHECKOUT" "canonical v2"
}

# --- R10a/R10b: the signal lands INSIDE the write phase --------------------
#
# The park is the `cp` that stages a managed tree, which happens after the lock
# is taken, after the journal is opened and after the first write was recorded
# as attempted. The lock must not come back until this process can no longer
# write, and no contender may acquire it in between.
sig_midwrite_case() { # <tag> <signal> <expected exit status>
  local tag="$1" sig="$2" want="$3" held_inc safe_rev

  sig_scenario "r10$tag"
  safe_rev="$(manifest_get '.applied_revision')"
  sig_launch cp "/staged" true update --json || return 1

  if ! sig_wait_parked 1; then
    bad "$tag the update could be stopped inside its write phase" \
      "$(cat "$SIGDIR/err" 2>/dev/null)"
    return 1
  fi
  ok "$tag the update is stopped inside its write phase"
  held_inc="$(lock_incarnation_now)"
  assert_ne "$tag and it holds the operation lock there" "$held_inc" ""
  assert_eq "$tag its journal is open at the write it attempted" \
    "$(jq -r '.state' "$(journal_path)" 2>/dev/null)" "IN_PROGRESS"

  # A contender arriving while the writer is stopped is refused, and is never
  # told to remove the lock a live owner is holding.
  run_afk update --json
  assert_eq "$tag a contender meeting the live writer is refused" \
    "$(jget '.operation.reason')" "CONCURRENT_OPERATION_IN_PROGRESS"
  assert_eq "$tag with the owner-action exit"        "$RUN_RC" "2"
  assert_contains "$tag it is told to wait, not to remove the lock" \
    "$(jget '.next_safe_action')" "Wait for the operation in progress to finish"
  assert_absent "$tag and is never sent to remove one by hand" \
    "$(jget '.next_safe_action')" "by hand"
  assert_eq "$tag and never that the owner could not be judged" \
    "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[]?.reason] | index("OPERATION_LOCK_OWNER_UNVERIFIABLE") != null')" "false"
  assert_eq "$tag the writer still holds the exact lock it took" \
    "$(lock_incarnation_now)" "$held_inc"

  kill -"$sig" "$VICTIM_PID" 2>/dev/null
  sig_settle

  # THE assertion. Reaching the tool a second time is what a released handler
  # that returned to the transaction does, and nothing else does it.
  assert_eq "$tag no managed write ran after the signal was handled" "$SIG_PARKED2" "false"
  assert_ne "$tag so the lock was never freed while the writer could still write" \
    "$SIG_LOCK_AT_PARK2" "FREED-WHILE-WRITING"
  assert_ne "$tag and no second writer could take the installation from under it" \
    "$SIG_CONTENDER_AT_PARK2" "ACQUIRED-ALONGSIDE-THE-WRITER"
  assert_eq "$tag the run terminated on the signal it was sent"      "$SIG_RC" "$want"
  assert_no_file "$tag and the lock is gone only now that it is dead" "$(lock_path)"
  assert_eq "$tag with nothing left of the release" "$(lock_residue)" ""
  assert_eq "$tag the journal stayed visible for recovery" \
    "$(jq -r '.state' "$(journal_path)" 2>/dev/null)" "IN_PROGRESS"
  assert_eq "$tag and the applied revision never moved" \
    "$(manifest_get '.applied_revision')" "$safe_rev"

  # The installation is neither busy nor bricked: the next command resolves the
  # interruption from the journal the trap deliberately left behind.
  run_afk update --json
  assert_eq "$tag the next run rolls the interrupted operation back" \
    "$(jget '.operation.result')" "RECOVERED"
  assert_eq "$tag and the one after it converges" "$(run_afk update --json; jget '.operation.result')" "CONVERGED"
  assert_eq "$tag leaving no lock behind" "$(lock_residue)" ""
}

sig_midwrite_case R10a TERM 143
sig_midwrite_case R10b INT  130

# --- R10c: the signal lands BEFORE the lock is acquired --------------------
#
# Nothing is held, so the release has nothing to do — and the run must still
# terminate rather than carry on and mutate an installation whose operator
# asked it to stop.
sig_scenario r10c
SAFE_REV="$(manifest_get '.applied_revision')"
FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"
JOURNAL_BEFORE="$(journal_fingerprint)"
sig_launch git "" false update --json
if sig_wait_parked 1; then
  ok "R10c the update is stopped before it takes the lock"
else
  bad "R10c the update is stopped before it takes the lock" "$(cat "$SIGDIR/err" 2>/dev/null)"
fi
assert_no_file "R10c nothing holds the lock there" "$(lock_path)"
kill -TERM "$VICTIM_PID" 2>/dev/null
sig_settle
assert_eq "R10c the run terminated on the signal"  "$SIG_RC" "143"
assert_no_file "R10c and took no lock on the way out" "$(lock_path)"
assert_eq "R10c it opened no journal"    "$(journal_fingerprint)" "$JOURNAL_BEFORE"
assert_eq "R10c and wrote nothing"       "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"
assert_eq "R10c the applied revision never moved" \
  "$(manifest_get '.applied_revision')" "$SAFE_REV"
run_afk update --json
assert_eq "R10c an installation nothing interrupted converges normally" \
  "$(jget '.operation.result')" "CONVERGED"

# --- R10d: the signal lands AFTER the commit, still holding the lock -------
#
# The authority transition has already happened; what is left is housekeeping
# that cannot change what the commit means. The release must happen exactly
# once, at the end, and the committed revision must stand.
sig_scenario r10d
TARGET_REV="$(git -C "$CHECKOUT" rev-parse HEAD)"
sig_launch jq '.state = "COMMITTED"' false update --json
if sig_wait_parked 1; then
  ok "R10d the update is stopped after its authority transition"
else
  bad "R10d the update is stopped after its authority transition" "$(cat "$SIGDIR/err" 2>/dev/null)"
fi
assert_eq "R10d the manifest already carries the target revision" \
  "$(manifest_get '.applied_revision')" "$TARGET_REV"
assert_ne "R10d and the lock is still held while housekeeping runs" \
  "$(lock_incarnation_now)" ""
kill -TERM "$VICTIM_PID" 2>/dev/null
sig_settle
assert_eq "R10d the run terminated on the signal" "$SIG_RC" "143"
assert_no_file "R10d and released the lock exactly once" "$(lock_path)"
assert_eq "R10d with nothing left of the release" "$(lock_residue)" ""
assert_eq "R10d the committed revision stands" \
  "$(manifest_get '.applied_revision')" "$TARGET_REV"

# --- R10e: the signal lands AFTER the ordinary release ---------------------
#
# The trap fires on a process that no longer owns anything. A release that was
# not exact-incarnation would remove whatever the lock path names by then —
# so a live owner is put there on purpose, and must survive.
sig_scenario r10e
TARGET_REV="$(git -C "$CHECKOUT" rev-parse HEAD)"
sig_launch jq '--argjson verification' false update --json
if sig_wait_parked 1; then
  ok "R10e the update is stopped after it released the lock"
else
  bad "R10e the update is stopped after it released the lock" "$(cat "$SIGDIR/err" 2>/dev/null)"
fi
assert_no_file "R10e it holds no lock there" "$(lock_path)"
write_live_lock
SUCCESSOR_INC="$(lock_incarnation_now)"
assert_ne "R10e a live successor holds the lock instead" "$SUCCESSOR_INC" ""
kill -TERM "$VICTIM_PID" 2>/dev/null
sig_settle
assert_eq "R10e the run terminated on the signal" "$SIG_RC" "143"
assert_eq "R10e and its trap removed nothing that was not its own" \
  "$(lock_incarnation_now)" "$SUCCESSOR_INC"
assert_eq "R10e the committed revision stands" \
  "$(manifest_get '.applied_revision')" "$TARGET_REV"
rm -rf "$(lock_path)"

head1 "12. F6-R11 — no terminating signal hands the lock back under a live write"
# ===========================================================================
# Section 11 pinned the shape where the signalled process HANDLES the signal
# and goes back to work. This is the other half of the same invariant, and the
# one R10 left open: a terminating signal the script does NOT trap.
#
# An untrapped fatal signal does not politely wait. Bash runs the EXIT trap —
# which is the release — and then dies at once, without waiting for the
# command it was running. The command it was running is a real write: a `cp`
# staging a managed tree, a child that is still alive and still copying when
# the lock comes back. A contender arriving in that window takes the
# installation from under a write that has not finished. Two owners, one
# installation, exactly as in section 11, reached from the other side.
#
# Trapping is what closes it: the handler is deferred until the running
# command returns, so the exit — and therefore the release — cannot happen
# while a child of this process can still write.
#
# The delivery shape is the whole point. A terminal hangup signals the process
# GROUP, which kills the writer along with the shell and is therefore benign;
# only `kill -HUP <pid>` — a supervisor, a pkill, an operator with the main
# pid — reaches the shell alone. That is the shape sig_launch already
# produces, and the shape every case here uses.

# The window this section is about: the signal has been delivered and the
# writer is still parked inside the staging copy, so this process can still
# write. The wrong behaviour shows up immediately (the shell is gone within
# milliseconds), so a bounded wait is enough to tell the two apart, and a
# correct run cannot be waited out — it is blocked in the park until the test
# releases it.
sig_alive_after_signal() {
  local i=0
  while (( i < 40 )); do
    kill -0 "$VICTIM_PID" 2>/dev/null || { printf 'false'; return 0; }
    i=$((i + 1)); sleep 0.05
  done
  printf 'true'
}

# Whether a signal can be delivered to anything this suite starts at all.
#
# A launcher that IGNORES a signal — `nohup`, or a supervisor that does the same
# — hands SIG_IGN to every descendant, and bash cannot trap a signal that was
# ignored on entry to the shell. The run under test then ignores it too: safe,
# because a signal that never arrives frees nothing, but it proves nothing
# either. That is worth detecting rather than living with, because both silent
# outcomes are lies — the case would report the kit as broken (the run finishes
# normally where the case expects it to die) when the truth is that the gate was
# launched somewhere it cannot ask the question.
sig_deliverable() { # <signal>
  [[ "$( ( trap 'true' "$1" 2>/dev/null; trap -p "$1" ) 2>/dev/null )" == *"'true'"* ]]
}

# --- R11a–R11e: the signal lands INSIDE the write phase, pid only ----------
sig_untrapped_case() { # <tag> <signal> <expected exit status>
  local tag="$1" sig="$2" want="$3" held_inc safe_rev alive lock_now

  if ! sig_deliverable "$sig"; then
    printf '  \033[33m!! SIG%s was ignored on entry to this suite, so nothing it starts can trap it\033[0m\n' "$sig"
    skip "$tag SIG$sig delivered pid-only inside the write phase — NOT RUN here"
    return 0
  fi

  sig_scenario "r11$tag"
  safe_rev="$(manifest_get '.applied_revision')"
  sig_launch cp "/staged" true update --json || return 1

  if ! sig_wait_parked 1; then
    bad "$tag the update could be stopped inside its write phase" \
      "$(cat "$SIGDIR/err" 2>/dev/null)"
    return 1
  fi
  ok "$tag the update is stopped inside its write phase"
  held_inc="$(lock_incarnation_now)"
  assert_ne "$tag and it holds the operation lock there" "$held_inc" ""
  assert_eq "$tag its journal is open at the write it attempted" \
    "$(jq -r '.state' "$(journal_path)" 2>/dev/null)" "IN_PROGRESS"

  kill -"$sig" "$VICTIM_PID" 2>/dev/null
  alive="$(sig_alive_after_signal)"

  # THE assertions. The staging copy has not returned, so this process can
  # still write — and what is true of the lock right now is what decides
  # whether a second owner could arrive.
  assert_eq "$tag the run does not die out from under the write it started" "$alive" "true"
  if [[ -n "$(lock_incarnation_now)" ]]; then lock_now="held"; else lock_now="FREED-UNDER-A-LIVE-WRITE"; fi
  assert_eq "$tag so the lock is not handed back while that write is in flight" \
    "$lock_now" "held"
  assert_eq "$tag and it is still the exact lock the writer took" \
    "$(lock_incarnation_now)" "$held_inc"

  # A contender meeting that window is refused, and is never told the owner
  # could not be judged.
  run_afk update --json
  assert_eq "$tag a contender meeting the signalled writer is refused" \
    "$(jget '.operation.reason')" "CONCURRENT_OPERATION_IN_PROGRESS"
  assert_eq "$tag with the owner-action exit" "$RUN_RC" "2"

  sig_settle

  # The section 11 witness still applies: handling the signal must not send
  # the transaction back to work either.
  assert_eq "$tag no managed write ran after the signal was handled" "$SIG_PARKED2" "false"
  assert_ne "$tag so the lock was never freed while the writer could still write" \
    "$SIG_LOCK_AT_PARK2" "FREED-WHILE-WRITING"
  assert_ne "$tag and no second writer could take the installation from under it" \
    "$SIG_CONTENDER_AT_PARK2" "ACQUIRED-ALONGSIDE-THE-WRITER"
  assert_eq "$tag the run terminated on the signal it was sent" "$SIG_RC" "$want"
  assert_no_file "$tag and the lock is gone only now that it is dead" "$(lock_path)"
  assert_eq "$tag with nothing left of the release" "$(lock_residue)" ""
  assert_eq "$tag the journal stayed visible for recovery" \
    "$(jq -r '.state' "$(journal_path)" 2>/dev/null)" "IN_PROGRESS"
  assert_eq "$tag and the applied revision never moved" \
    "$(manifest_get '.applied_revision')" "$safe_rev"

  run_afk update --json
  assert_eq "$tag the next run rolls the interrupted operation back" \
    "$(jget '.operation.result')" "RECOVERED"
  assert_eq "$tag and the one after it converges" \
    "$(run_afk update --json; jget '.operation.result')" "CONVERGED"
  assert_eq "$tag leaving no lock behind" "$(lock_residue)" ""
}

# HUP is the reachable one: a supervisor or an operator signalling the main
# pid. The rest terminate this shell by default too and cost nothing to hold
# to the same rule, so the invariant has no holes left to re-derive. PIPE is
# the odd one — it cannot fire while the lock is held today, because nothing
# in the transaction writes a byte to stdout or stderr — but that is a
# property of code this file does not own, so it is pinned here as well.
sig_untrapped_case R11a HUP  129
sig_untrapped_case R11b USR1 138
sig_untrapped_case R11c USR2 140
sig_untrapped_case R11d ALRM 142
sig_untrapped_case R11e PIPE 141

# --- R11f: QUIT is deliberately NOT trapped --------------------------------
#
# Bash ignores SIGQUIT, so Ctrl-\ during a transaction interrupts nothing: the
# run carries on and finishes. Trapping it would newly KILL runs that succeed
# today, and it could not free the lock in any case because it never reaches
# the shell. This case is here so the next reader can see that the omission is
# a decision, and so that adding the handler fails a gate instead of passing
# review as a tidy-up.
sig_scenario r11f
TARGET_REV="$(git -C "$CHECKOUT" rev-parse HEAD)"
sig_launch cp "/staged" false update --json
if sig_wait_parked 1; then
  ok "R11f the update is stopped inside its write phase"
else
  bad "R11f the update is stopped inside its write phase" "$(cat "$SIGDIR/err" 2>/dev/null)"
fi
kill -QUIT "$VICTIM_PID" 2>/dev/null
assert_eq "R11f a quit signal does not terminate the transaction" \
  "$(sig_alive_after_signal)" "true"
assert_ne "R11f which still holds its lock" "$(lock_incarnation_now)" ""
sig_settle
assert_eq "R11f the interrupted-looking run in fact completed" "$SIG_RC" "0"
assert_eq "R11f converging on the revision it was asked for" \
  "$(manifest_get '.applied_revision')" "$TARGET_REV"
assert_no_file "R11f and released its lock on the way out" "$(lock_path)"
assert_eq "R11f with nothing left of the release" "$(lock_residue)" ""

# ===========================================================================
head1 "13. AFK-LC-1 — nested components sharing a root converge in one run"
# ===========================================================================

# The empty-tree predicate is the discriminator FR-26 leans on: an empty
# scaffold owns nothing, a root with even one non-excluded file owns content.
LC="$TMPROOT/lc1"; mkdir -p "$LC"

mkdir -p "$LC/emptytree"
assert_eq "an empty directory reads as an empty managed tree" \
  "$(afk_managed_tree_empty "$LC/emptytree" ""; printf '%s' "$?")" "0"

mkdir -p "$LC/excludedonly/bin" "$LC/excludedonly/lifecycle"
printf 'x\n' > "$LC/excludedonly/bin/thing"
assert_eq "a root holding only excluded members is still empty" \
  "$(afk_managed_tree_empty "$LC/excludedonly" "bin,lib,lifecycle"; printf '%s' "$?")" "0"

mkdir -p "$LC/hasfile"
printf 'stray\n' > "$LC/hasfile/STRAY"
assert_eq "a root with a non-excluded file is NOT empty (FR-26)" \
  "$(afk_managed_tree_empty "$LC/hasfile" "bin,lib,lifecycle"; printf '%s' "$?")" "1"

mkdir -p "$LC/haslink"
ln -s /dev/null "$LC/haslink/LINK"
assert_eq "a root with a non-excluded symlink is NOT empty" \
  "$(afk_managed_tree_empty "$LC/haslink" ""; printf '%s' "$?")" "1"

assert_eq "a directory that does not exist is not an empty tree" \
  "$(afk_managed_tree_empty "$LC/nope" ""; printf '%s' "$?")" "1"

# afk_mkdir_tracked records exactly what it creates, and the scaffold remover
# takes back exactly that — empty-only, so nothing with content is ever removed.
mkdir -p "$LC/base/keepdir"
printf 'mine\n' > "$LC/base/keepdir/mine.txt"
BASE_FP="$(fingerprint_tree "$LC/base")"
AFK_OP_CREATED_DIRS=""
afk_mkdir_tracked "$LC/base/afk-runtime/lifecycle"
assert_file "the nested scaffold now exists" "$LC/base/afk-runtime/lifecycle"
assert_eq "the created root is recognized as operation-created" \
  "$(afk_op_created_dir "$LC/base/afk-runtime"; printf '%s' "$?")" "0"
assert_eq "the nested scaffold is recognized as operation-created" \
  "$(afk_op_created_dir "$LC/base/afk-runtime/lifecycle"; printf '%s' "$?")" "0"
assert_eq "a pre-existing directory is NOT claimed as operation-created" \
  "$(afk_op_created_dir "$LC/base/keepdir"; printf '%s' "$?")" "1"
afk_remove_created_scaffold
assert_no_file "the scaffold is fully removed on abort" "$LC/base/afk-runtime"
assert_eq "and pre-existing content is byte-for-byte untouched" \
  "$(fingerprint_tree "$LC/base")" "$BASE_FP"

# The safety of using rmdir: a "created" directory that ended up holding content
# is never removed, so a real write can never be deleted by the cleanup.
AFK_OP_CREATED_DIRS=""
afk_mkdir_tracked "$LC/base/afk-runtime/lifecycle"
printf 'a write landed here\n' > "$LC/base/afk-runtime/lifecycle/written"
afk_remove_created_scaffold
assert_file "a created dir that gained content survives the cleanup" \
  "$LC/base/afk-runtime/lifecycle/written"
rm -rf "$LC/base/afk-runtime"
AFK_OP_CREATED_DIRS=""

# --- AC-1: a nested install completes in one run --------------------------
restore_golden installed
# Remove the runtime BEFORE adoption so its four components — the shared root
# and the bin/lib/lifecycle members that live inside it — are absent AND
# unrecorded: exactly the shape that used to abort "stale before its first
# write" the moment the backup phase created the shared parent.
rm -rf "$HOMEDIR/.agents/skills/afk-runtime"
adopt_host
run_afk update --json
assert_eq "the nested install converges in a single run"  "$RUN_RC" "0"
assert_eq "and reports itself converged"                  "$(jget '.operation.result')" "CONVERGED"
assert_eq "the shared root is installed"                  "$(plan_field afk-runtime-adapters action)" "INSTALL"
assert_eq "the bin member is installed"                   "$(plan_field afk-runtime-bin action)" "INSTALL"
assert_eq "the lib member is installed"                   "$(plan_field afk-runtime-lib action)" "INSTALL"
assert_eq "the nested release-policy file is installed"   "$(plan_field afk-runtime-release-policy action)" "INSTALL"
assert_file "the shared root exists afterwards"           "$HOMEDIR/.agents/skills/afk-runtime/README"
assert_file "the bin member exists"                       "$HOMEDIR/.agents/skills/afk-runtime/bin/agent-flow-kit"
assert_file "the lib member exists"                       "$HOMEDIR/.agents/skills/afk-runtime/lib/afk-common.sh"
assert_file "the nested file exists"                      "$HOMEDIR/.agents/skills/afk-runtime/lifecycle/release-policy.json"
assert_eq "the applied state was committed"               "$(jget '.operation.applied_state_committed')" "true"
run_afk verify --json
assert_eq "and every installed component verifies"        "$(jget '.extra.verification.verified')" "true"
run_afk status --json
assert_eq "the shared root reports CURRENT"               "$(component_field afk-runtime-adapters .state)" "CURRENT"
assert_eq "the nested member reports CURRENT"             "$(component_field afk-runtime-release-policy .state)" "CURRENT"

# --- AC-3: an abort after the shared root is scaffolded leaves nothing -----
restore_golden installed
rm -rf "$HOMEDIR/.agents/skills/afk-runtime"
adopt_host
GOOD_SHA="$(manifest_get '.applied_revision')"
BEFORE_FP="$(fingerprint_tree "$HOMEDIR/.agents/skills")"
# The same deterministic write failure the rollback scenario uses, planted in a
# runtime member: the transaction opens, the backup phase scaffolds the shared
# root, the root and its earlier siblings write, and this member then refuses to
# converge. The abort must leave no trace of the scaffold it created.
mkdir -p "$SC/faraway"; printf 'far away\n' > "$SC/faraway/thing.md"
ln -s "$SC/faraway/thing.md" "$CHECKOUT/lib/escape"
git_commit_all "$CHECKOUT" "a runtime member gains an escaping link"
run_afk update --json
assert_eq "the failed nested install is rolled back"      "$(jget '.operation.result')" "ROLLED_BACK"
assert_eq "restoration completed"                         "$(jget '.operation.rollback_state')" "COMPLETE"
assert_no_file "no shared-root scaffold survives the abort" \
  "$HOMEDIR/.agents/skills/afk-runtime"
assert_eq "the skills tree is byte-for-byte as before the attempt" \
  "$(fingerprint_tree "$HOMEDIR/.agents/skills")" "$BEFORE_FP"
assert_eq "the applied revision never moved"              "$(manifest_get '.applied_revision')" "$GOOD_SHA"
run_afk verify --json
assert_eq "the untouched installation still verifies"     "$(jget '.extra.verification.verified')" "true"

# --- AC-4: an empty leftover root is planned as an install, not blocked ----
restore_golden installed
rm -rf "$HOMEDIR/.agents/skills/afk-runtime"
adopt_host
# The 2026-09-17 shape: an earlier aborted op left an empty shared root behind.
# Unrecorded and holding no file, it must plan as an install rather than block
# every later plan with COMPONENT_NOT_RECORDED.
mkdir -p "$HOMEDIR/.agents/skills/afk-runtime/lifecycle"
run_afk update --plan --json
assert_eq "the empty leftover root is planned as an install" \
  "$(plan_field afk-runtime-adapters action)" "INSTALL"
assert_eq "with the not-installed reason, never COMPONENT_NOT_RECORDED" \
  "$(plan_field afk-runtime-adapters reason)" "COMPONENT_NOT_INSTALLED"
run_afk update --json
assert_eq "and the leftover no longer blocks convergence"  "$RUN_RC" "0"
assert_eq "the run converges"                              "$(jget '.operation.result')" "CONVERGED"
assert_file "the shared root now carries canonical content" \
  "$HOMEDIR/.agents/skills/afk-runtime/README"

# --- AC-4 / FR-26: a non-empty unowned root still blocks ------------------
restore_golden installed
rm -rf "$HOMEDIR/.agents/skills/afk-runtime"
adopt_host
# A root that CONTAINS an unowned file is content this kit may not claim: it
# stays BLOCKED, exactly as before, so the fix never widens what gets written.
mkdir -p "$HOMEDIR/.agents/skills/afk-runtime"
printf 'not ours to overwrite\n' > "$HOMEDIR/.agents/skills/afk-runtime/STRAY"
STRAY_ID="$(hash_of_file "$HOMEDIR/.agents/skills/afk-runtime/STRAY")"
run_afk update --plan --json
assert_eq "a non-empty unowned root is refused"           "$(plan_field afk-runtime-adapters action)" "BLOCKED"
assert_eq "with COMPONENT_NOT_RECORDED (FR-26)"           "$(plan_field afk-runtime-adapters reason)" "COMPONENT_NOT_RECORDED"
run_afk update --json
assert_ne "the refused plan performs no mutation"         "$RUN_RC" "0"
assert_eq "and the unowned file is left byte-for-byte"    "$(hash_of_file "$HOMEDIR/.agents/skills/afk-runtime/STRAY")" "$STRAY_ID"

# --- AC-2 NEGATIVE: the op-created-dir exclusion must not blind the guard --
# The positive path above proves an empty root the operation created is excused.
# This pins the other side of the same seam: a GENUINE external file lands in
# that op-created shared root before the root component's write, so the root is
# no longer empty. afk_managed_tree_empty must then return false, the exclusion
# must NOT fire, and afk_component_prewrite_ok must raise
# PLAN_STALE_DESTINATION_CHANGED — mutation refused, unowned content not claimed.
# Injected deterministically through the same function seam the unit tests above
# use, not a concurrent process. If this assertion fails (result ":0:"), the
# exclusion is blinding the freshness guard and the fix is unsafe.
NEG_SAVED_SKILLS="$AFK_SKILLS_HOME"; NEG_SAVED_KIT="$AFK_KIT_ROOT"
AFK_SKILLS_HOME="$LC/neg/skills"; AFK_KIT_ROOT="$LC/neg/checkout"
mkdir -p "$AFK_SKILLS_HOME" "$AFK_KIT_ROOT/adapters"
printf 'canonical adapter\n' > "$AFK_KIT_ROOT/adapters/README"
AFK_OP_CREATED_DIRS=""
afk_mkdir_tracked "$AFK_SKILLS_HOME/afk-runtime"          # the transaction's own scaffold
printf 'planted by someone else\n' > "$AFK_SKILLS_HOME/afk-runtime/INTRUDER"
NEG_ROW="$(afk_component_row afk-runtime-adapters)"
afk_observe_component "$NEG_ROW"                          # to read the declared type
NEG_ENTRY="$(jq -nc --arg c afk-runtime-adapters --arg t "$AFK_OB_WANT" \
  '{component:$c, expected_destination_identity:null, guard:{expected_type:$t}}')"
NEG_RESULT="$(afk_component_prewrite_ok "$NEG_ENTRY"; printf ':%s:%s' "$?" "$AFK_STEP_REASON")"
assert_eq "AC-2 negative: a genuine external file in the op-created root is NOT excused — stale is raised" \
  "$NEG_RESULT" ":1:PLAN_STALE_DESTINATION_CHANGED"
AFK_SKILLS_HOME="$NEG_SAVED_SKILLS"; AFK_KIT_ROOT="$NEG_SAVED_KIT"; AFK_OP_CREATED_DIRS=""

# ===========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
