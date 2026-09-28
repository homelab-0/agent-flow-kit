#!/usr/bin/env bash
# primitive-equivalence-tests.sh — the lifecycle CLI's behaviour is unchanged
# between a baseline tree (a Git ref) and this working tree.
#
# Built for the hot-path primitive rewrite (AD-20), and useful for any change
# that must not move output: every fixture is built ONCE through the baseline
# CLI, snapshotted, and then restored to the SAME absolute path before every
# run, so the baseline and the candidate see byte-identical hosts. For each
# (fixture, verb) the exit code, stdout, stderr and the resulting host tree are
# compared. Only timestamps and timestamp-derived operation ids are masked
# (plus, in stderr only, the source line number in bash's own diagnostics, and
# — a PM-approved mask, AFK-TP-3 CR-1 — adjacent duplicates of bash's
# "Permission denied" diagnostic on the BASELINE side, see collapse_denied);
# anything else that differs is a failure of the code, never of the mask.
#
# The candidate is also run with AFK_HASH_FORCE_PORTABLE=1, which forces the
# per-file hashing path macOS takes (shasum where installed), so both hashing
# paths are proven against the same baseline.
#
# Nothing here touches the real HOME, installation or Git state. It is a
# standalone tool, not part of tests/run-tests.sh.
#
# Usage: tests/primitive-equivalence-tests.sh
#   AFK_EQUIV_BASE=<ref>        baseline (default: merge-base with origin/master;
#                               a baseline identical to the candidate FAILS)
#   AFK_EQUIV_ONLY="a b"        only these fixtures ("none": primitives only)
#   AFK_EQUIV_VERBS="status"    only these verbs (status verify plan adopt update approve)
#   AFK_EQUIV_DRIFTS="none"     drift-between-boundaries cases (see DRIFTS below)
#   AFK_EQUIV_KEEP=<dir>        keep every raw output there
#   AFK_EQUIV_OBSLOG=<dir>      keep the candidate's observation log per run
# Exit:  0 all identical, 1 any difference.

if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 5 ]]; then
  printf 'primitive-equivalence-tests.sh requires bash 5+, found %s\n' \
    "${BASH_VERSION:-unknown}" >&2
  exit 2
fi

set -uo pipefail
unset AFK_ORCA_BIN ORCA_CLI_COMMAND AGENT_ROUTER_URL AGENT_ROUTER_TOKEN \
      AGENT_STAMP_VALIDATE_CATALOG_PATH AFK_LIB_DIR AFK_HASH_FORCE_PORTABLE CDPATH

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BASE="${AFK_EQUIV_BASE:-$(git -C "$KIT_ROOT" merge-base HEAD origin/master 2>/dev/null)}"
[[ -n "$BASE" ]] || { printf 'no baseline: set AFK_EQUIV_BASE (no merge-base with origin/master)\n' >&2; exit 1; }
FIXTURES="${AFK_EQUIV_ONLY:-installed clean ahead drift redirect missing unreadable unrecognized interrupted}"
VERBS="${AFK_EQUIV_VERBS:-status verify plan adopt update approve}"
# Drift injected between two safety boundaries of ONE mutating run (AD-19),
# as <fixture>:<verb>:<boundary>:<change>:<expected result/reason>.
DRIFTS="${AFK_EQUIV_DRIFTS:-ahead:update:lock:codex:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED
ahead:update:prepare:runtime:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED
ahead:update:applied:humanizer:ROLLED_BACK/PLAN_STALE_DESTINATION_CHANGED
ahead:update:build:codex:ROLLED_BACK/VERIFICATION_FAILED
ahead:update:lock:commit:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED
ahead:update:lock:dirty:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED
ahead:update:lock:ignored:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED
ahead:update:lock:assume:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED
ahead:update:lock:symlink:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED
installed:adopt:lock:codex:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED
installed:adopt:prepare:humanizer:STALE_PLAN/PLAN_STALE_DESTINATION_CHANGED}"
# AFK_EQUIV_OBSLOG=<dir>: the candidate's observation log per run is kept there.

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

export GIT_AUTHOR_NAME="afk-test" GIT_AUTHOR_EMAIL="afk@test.invalid"
export GIT_COMMITTER_NAME="afk-test" GIT_COMMITTER_EMAIL="afk@test.invalid"

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | head -20 | sed 's/^/        /'; FAIL=$((FAIL + 1)); }

# Both kits run from ONE absolute path (swapped in by rename), so no path of
# the harness itself can differ between the two outputs. The candidate is the
# baseline tree with this working tree's bin/ and lib/ laid over it.
KIT="$TMPROOT/kit"
mkdir -p "$TMPROOT/k-baseline" "$TMPROOT/k-candidate"
if ! git -C "$KIT_ROOT" archive "$BASE" | tar -x -C "$TMPROOT/k-baseline" ||
   ! git -C "$KIT_ROOT" archive "$BASE" | tar -x -C "$TMPROOT/k-candidate"; then
  printf 'cannot materialize baseline %s\n' "$BASE" >&2; exit 1
fi
cp -R "$KIT_ROOT/bin/." "$TMPROOT/k-candidate/bin/"
cp -R "$KIT_ROOT/lib/." "$TMPROOT/k-candidate/lib/"
printf 'baseline %s (%s) vs working tree %s\n' "$BASE" \
  "$(git -C "$KIT_ROOT" rev-parse --short "$BASE")" "$KIT_ROOT"
# Comparing a tree with itself proves nothing, so it is a failure, not a pass.
if diff -rq "$TMPROOT/k-baseline/lib" "$TMPROOT/k-candidate/lib" >/dev/null &&
   diff -rq "$TMPROOT/k-baseline/bin" "$TMPROOT/k-candidate/bin" >/dev/null; then
  printf '  \033[31mFAIL\033[0m baseline bin/ and lib/ are identical to the candidate: nothing is compared\n'
  exit 1
fi

# The drift driver: each side's own CLI with the final dispatch cut off, one
# change injected at a named boundary through a wrapper around a function both
# sides call at that point, then the real dispatch. It lives beside the CLI so
# it resolves the same install root.
for side in baseline candidate; do
  cli="$TMPROOT/k-$side/bin/agent-flow-kit"
  [[ "$(tail -n 2 "$cli")" == $'afk_main "$@"\nexit $?' ]] || { printf 'unexpected CLI tail in %s\n' "$side" >&2; exit 1; }
  { sed '$d' "$cli" | sed '$d'; cat <<'DRIVER'
afk_equiv_fired=""
afk_equiv_fire() { # <boundary>
  local b="${AFK_EQUIV_DRIFT%%:*}" c="${AFK_EQUIV_DRIFT#*:}"
  [[ "$1" == "$b" && -z "$afk_equiv_fired" ]] || return 0
  afk_equiv_fired=1
  case "$c" in
    runtime)   printf 'drift\n' >> "$HOME/.agents/skills/afk-runtime/README" ;;
    codex)     printf 'drift\n' >> "$HOME/.codex/AGENTS.md" ;;
    humanizer) printf 'drift\n' >> "$HOME/.agents/skills/humanizer/SKILL.md" ;;
    commit)    printf 'humanizer v2\n' > "$AFK_KIT_ROOT/files/humanizer/SKILL.md"
               git -C "$AFK_KIT_ROOT" add -A >/dev/null 2>&1
               GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
                 git -C "$AFK_KIT_ROOT" -c commit.gpgsign=false commit -q --no-verify -m v2 >/dev/null 2>&1 ;;
    dirty)     printf 'humanizer inner v2\n' > "$AFK_KIT_ROOT/files/humanizer/skills/humanizer/SKILL.md" ;;
    assume)    git -C "$AFK_KIT_ROOT" update-index --assume-unchanged files/humanizer/SKILL.md
               printf 'humanizer hidden v2\n' > "$AFK_KIT_ROOT/files/humanizer/SKILL.md" ;;
    symlink)   printf 'codex guidance v2\n' > "${AFK_KIT_ROOT%/checkout}/codex-source.md" ;;
    ignored)   printf 'ignored notes v2\n' > "$AFK_KIT_ROOT/files/model-router/notes.local" ;;
  esac
}
for f in afk_lock_acquire afk_journal_write afk_journal_step_result afk_build_manifest_json; do
  eval "afk_equiv_orig_$f() $(declare -f "$f" | tail -n +2)"
done
afk_lock_acquire() { afk_equiv_fire lock; afk_equiv_orig_afk_lock_acquire "$@"; }
afk_journal_write() { [[ "$1" != PREPARING ]] || afk_equiv_fire prepare; afk_equiv_orig_afk_journal_write "$@"; }
afk_journal_step_result() {
  local rc=0; afk_equiv_orig_afk_journal_step_result "$@" || rc=$?
  [[ "$2" != APPLIED ]] || afk_equiv_fire applied; return "$rc"
}
afk_build_manifest_json() { afk_equiv_fire build; afk_equiv_orig_afk_build_manifest_json "$@"; }
afk_main "$@"
exit $?
DRIVER
  } > "$TMPROOT/k-$side/bin/afk-equiv-drift"
  # The fault driver: the same CLI with one failure injected into a function
  # both sides call. "table": the declared inventory cannot be enumerated.
  # "observe": one component (humanizer) cannot be observed.
  { sed '$d' "$cli" | sed '$d'; cat <<'DRIVER'
case "${AFK_EQUIV_FAULT:-}" in
  table)   afk_component_table() { return 1; } ;;
  observe) eval "afk_equiv_orig_observe() $(declare -f afk_observe_component | tail -n +2)"
           afk_observe_component() { [[ "$1" != humanizer\|* ]] || return 1; afk_equiv_orig_observe "$@"; } ;;
esac
afk_main "$@"
exit $?
DRIVER
  } > "$TMPROOT/k-$side/bin/afk-equiv-fault"
done

# --- fixtures (the shapes of tests/lifecycle-mutation-tests.sh) -------------

FX="$TMPROOT/fx" HOMEDIR="$TMPROOT/fx/home" CHECKOUT="$TMPROOT/fx/checkout"
mkdir -p "$TMPROOT/obs"
# The declared inventory size, from the candidate's own table.
COMPONENTS="$(bash -c '. "$1/afk-common.sh"; . "$1/afk-inventory.sh"
  AFK_SKILLS_HOME=/s AFK_CLAUDE_HOME=/c AFK_CODEX_HOME=/x; afk_component_table | grep -c .' _ "$KIT_ROOT/lib")"
[[ "$COMPONENTS" =~ ^[1-9][0-9]*$ ]] || { printf 'cannot count the declared inventory\n' >&2; exit 1; }

git_commit_all() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" -c commit.gpgsign=false commit -q --no-verify -m "$2" >/dev/null 2>&1; }

make_checkout() { # <dir>
  local d="$1"
  mkdir -p "$d/adapters" "$d/bin" "$d/lib" "$d/lifecycle" "$d/files/model-router/scripts" "$d/files/humanizer/skills/humanizer"
  printf '%s\n' '{"kit_id": "agent-flow-kit", "lifecycle_schema_version": "1.0",' \
    '"state_schema_version": "1.0", "result_schema_version": "1.0", "default_branch": "master",' \
    '"managed_inputs": ["adapters", "bin", "lib", "files", "lifecycle"]}' > "$d/lifecycle/kit.json"
  printf 'model-router skill v1\n' > "$d/files/model-router/SKILL.md"
  printf 'dispatch v1\n' > "$d/files/model-router/scripts/dispatch.sh"
  printf 'launcher:\n  router_endpoint: https://canonical.invalid\n' > "$d/files/model-router/subscriptions.yaml"
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

install_kit() { # <home> <checkout>
  local h="$1" c="$2" rt="$1/.agents/skills/afk-runtime"
  mkdir -p "$h/.agents/skills" "$h/.claude/skills" "$h/.codex"
  cp -R "$c/adapters" "$rt"
  mkdir -p "$rt/bin" "$rt/lib" "$rt/lifecycle"
  cp -R "$c/bin/." "$rt/bin/"; cp -R "$c/lib/." "$rt/lib/"
  cp "$c/lifecycle/release-policy.json" "$rt/lifecycle/release-policy.json"
  cp -R "$c/files/model-router" "$h/.agents/skills/model-router"
  cp -R "$c/files/humanizer" "$h/.agents/skills/humanizer"
  ln -s "$h/.agents/skills/model-router" "$h/.claude/skills/model-router"
  ln -s "$h/.agents/skills/humanizer" "$h/.claude/skills/humanizer"
  { printf '# my own notes\n# >>> agent-flow-kit managed section: claude-global-policy >>>\n'
    cat "$c/files/claude-global-CLAUDE.md"
    printf '# <<< agent-flow-kit managed section: claude-global-policy <<<\n# trailing note\n'
  } > "$h/.claude/CLAUDE.md"
  cp "$c/files/codex-AGENTS.md" "$h/.codex/AGENTS.md"
}

RUN_RC=0
run_cli() { # <baseline|candidate> <out-prefix> <args...>
  local side="$1" out="$2"; shift 2
  mv "$TMPROOT/k-$side" "$KIT"
  ( [[ "$side" != candidate ]] || export AFK_TEST_OBSERVATION_LOG="$TMPROOT/obs/${out##*/}.log"
    cd "$FX" && HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
      bash "$KIT/bin/${ENTRY:-agent-flow-kit}" "$@" >"$out.stdout" 2>"$out.stderr" )
  RUN_RC=$?
  mv "$KIT" "$TMPROOT/k-$side"
  printf '%s\n' "$RUN_RC" > "$out.rc"
}

build_fixture() { # <name>
  rm -rf "$FX"; mkdir -p "$HOMEDIR" "$CHECKOUT"
  make_checkout "$CHECKOUT"
  install_kit "$HOMEDIR" "$CHECKOUT"
  [[ "$1" == installed ]] && return 0
  if [[ "$1" == unrecognized ]]; then
    # Not adopted, and one tree matches no canonical or prior revision: adopt
    # needs an explicit approval of its plan identity.
    printf 'locally authored\n' >> "$HOMEDIR/.agents/skills/humanizer/SKILL.md"
    return 0
  fi
  run_cli baseline "$TMPROOT/build-$1" adopt --json
  [[ "$RUN_RC" == 0 ]] || { bad "fixture $1: baseline adopt established ownership" "exit $RUN_RC"; return 1; }
  case "$1" in
    ahead)
      printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
      printf 'policy line one\npolicy line two\npolicy line three\n' > "$CHECKOUT/files/claude-global-CLAUDE.md"
      # An ignored file inside a managed input: Git never reports an edit to
      # it, but the canonical tree identity hashes it.
      printf '*.local\n' > "$CHECKOUT/.gitignore"
      printf 'ignored notes v1\n' > "$CHECKOUT/files/model-router/notes.local"
      # A committed symlink source whose target lives outside the repository:
      # the file identity is read through it, and Git never looks there.
      mv "$CHECKOUT/files/codex-AGENTS.md" "$FX/codex-source.md"
      ln -s "$FX/codex-source.md" "$CHECKOUT/files/codex-AGENTS.md"
      git_commit_all "$CHECKOUT" "canonical v2" ;;
    drift)
      printf 'locally edited\n' >> "$HOMEDIR/.agents/skills/humanizer/SKILL.md"
      printf 'edited\n' >> "$HOMEDIR/.codex/AGENTS.md" ;;
    redirect)
      mkdir -p "$FX/elsewhere"; cp -R "$HOMEDIR/.agents/skills/humanizer/." "$FX/elsewhere/"
      ln -sfn "$FX/elsewhere" "$HOMEDIR/.claude/skills/humanizer"
      ln -s "$FX/elsewhere/SKILL.md" "$HOMEDIR/.agents/skills/model-router/escape.md" ;;
    missing)
      rm -rf "$HOMEDIR/.agents/skills/humanizer" "$HOMEDIR/.codex/AGENTS.md" ;;
    interrupted)
      # An operation that never closed its journal: the next mutation must
      # resolve it (FR-45) before planning anything new.
      j="$HOMEDIR/.local/state/agent-flow-kit/journal.json"
      jq -c '.state = "IN_PROGRESS"' "$j" > "$j.x" && mv "$j.x" "$j" ;;
  esac
  return 0
}

# The golden stays copyable; `unreadable` gets its mode-000 member on restore.
restore_fixture() { # <name>
  chmod -R u+rwX "$FX" 2>/dev/null; rm -rf "$FX"
  cp -a "$TMPROOT/golden-$1" "$FX"
  [[ "$1" != unreadable ]] || chmod 000 "$HOMEDIR/.agents/skills/model-router/scripts/dispatch.sh"
}

# Timestamps and the ids derived from them are the only masked fields.
TS_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z'
mask() { # <file> — prints a normalized copy
  sed -E -e "s/$TS_RE/<TS>/g" -e 's/op-[0-9]{8}T[0-9]{6}Z?-[0-9A-Za-z.-]+/<OPID>/g' \
         -e 's/[0-9]{8}T[0-9]{6}Z?-[0-9]+-[0-9A-Za-z]+/<OPID>/g' "$1"
}

# The host after the run: every path, its type, mode and content or target.
# Kit state files carry timestamps, so they are compared masked.
host_state() {
  ( cd "$FX" && find . -path ./checkout/.git -prune -o -print0 | LC_ALL=C sort -z |
    while IFS= read -r -d '' p; do
      if [[ -L "$p" ]]; then printf 'L %s -> %s\n' "$p" "$(readlink -- "$p")"
      elif [[ -d "$p" ]]; then printf 'D %s %s\n' "$p" "$(stat -c %a -- "$p" 2>/dev/null || stat -f %Lp -- "$p")"
      elif [[ -r "$p" ]]; then printf 'F %s %s %s\n' "$p" "$(stat -c %a -- "$p" 2>/dev/null || stat -f %Lp -- "$p")" "$(mask "$p" | cksum)"
      else printf 'U %s\n' "$p"; fi
    done ) | mask /dev/stdin
}

verb_args() {
  case "$1" in
    status) printf '%s\n' status --json ;;
    verify) printf '%s\n' verify --json ;;
    plan)   printf '%s\n' update --json --plan ;;
    adopt)  printf '%s\n' adopt --json ;;
    update) printf '%s\n' update --json ;;
    approve) printf '%s\n' adopt --json --approve-plan "$APPROVAL" ;;
  esac
}

# stderr alone also masks the SOURCE LINE bash prints in its own diagnostics
# ("afk-common.sh: line 122: <path>: Permission denied"): that number moves
# with any edit to the file. The message and the path still match.
# PM-approved mask (AFK-TP-3 CR-1), stderr only: ADJACENT duplicates of exactly
# bash's "<file>: line N: <path>: Permission denied" diagnostic collapse to one
# line. Bash prints it once per observation pass that hashes an unreadable
# file, and AD-19 removes the passes that repeated one. Nothing else collapses,
# and only the BASELINE is collapsed: a candidate that repeated the line would
# still differ.
collapse_denied() { # <part>
  if [[ "$1" != stderr ]]; then cat; return; fi
  awk '/\.sh: line N: .*: Permission denied$/ && $0 == prev { next } { print; prev = $0 }'
}

compare_run() { # <label> <baseline-prefix> <candidate-prefix> [parts]
  local label="$1" a="$2" b="$3" part d re
  for part in ${4:-rc stdout stderr host}; do
    re=''; [[ "$part" != stderr ]] || re='s/(\.sh: line )[0-9]+:/\1N:/'
    if d="$(diff <(mask "$a.$part" | sed -E "$re" | collapse_denied "$part") \
                 <(mask "$b.$part" | sed -E "$re"))"; then :; else
      bad "$label: $part identical" "$d"; return
    fi
  done
  if [[ -n "${4:-}" ]]; then ok "$label: $4 identical"; return; fi
  ok "$label: exit $(cat "$a.rc"), JSON, stderr and host state identical"
}

# Candidate only (AD-19): the full-inventory passes a run made, in order, and
# which functions observed a single component. A read-only verb observes once
# (O1); a mutation that took the lock adds O2, and O4 once its writes are
# verified; a run whose report no ledger still describes (a rollback) adds one
# "report" pass. Per-component observations belong to the pass itself, the
# pre-write guard (O3), the post-write proof and restoration only.
check_points() { # <label> <candidate-prefix>
  local log="$TMPROOT/obs/${2##*/}.log" got result per bad_caller n want
  got="$(awk 'NF == 1' "$log" 2>/dev/null | tr '\n' ' ')"; got="${got% }"
  result="$(jq -r '.operation.result // ""' "$2.stdout" 2>/dev/null)"
  per="$(awk 'NF == 2 && $1 == "afk_observation_pass"' "$log" 2>/dev/null | wc -l | tr -d ' ')"
  bad_caller="$(awk 'NF == 2 && $1 !~ /^afk_(observation_pass|component_prewrite_ok|component_apply|restoration_verified|recover_interrupted)$/ {print $1}' "$log" 2>/dev/null | sort -u | tr '\n' ' ')"
  n="$(wc -w <<<"$got" | tr -d ' ')"
  case "$result" in
    CONVERGED|ADOPTED) want="^O1 O2 O4$" ;;
    *) want="^O1( O2( O4)?( report)?)?$" ;;
  esac
  if [[ "$got" =~ $want && "$per" == "$((n * COMPONENTS))" && -z "$bad_caller" ]]; then
    ok "$1: observed at ${got:-nothing}${result:+ ($result)}"
  else
    bad "$1: observes only at O1-O4" "passes '$got' result '$result' pass-entries $per stray callers '$bad_caller'"
  fi
}

# --- primitives, called directly: every edge the CLI fixtures cannot reach ---
#
# One driver runs the same case list against the baseline and the candidate
# afk-common.sh (each in its own bash with pipefail, as the CLI runs) and
# prints every result as `rc|%q-quoted output`. The two transcripts must match.

U="$TMPROOT/u"
mkdir -p "$U/d/sub" "$U/t/sub" "$U/big" "$U/locked" "$U/nl"$'\n' "$U/odd"
printf 'f\n' > "$U/d/f"; printf 'a\n' > "$U/t/a"; printf 'b\n' > "$U/t/sub/b.txt"
printf 'x\n' > "$U/t/sub/x"; printf 'y\n' > "$U/locked/y"; printf 'z\n' > "$U/nl"$'\n'/z
for n in $'new\nline' $'tab\there' 'back\slash' 'sp ace' '-dash' 'HASHRC=0' 'FINDRC=0'; do printf '%s\n' "$n" > "$U/odd/$n"; done
ln -s d "$U/l1"; ln -s d/f "$U/l2"; ln -s /nonexistent/x "$U/l3"; ln -s l4 "$U/l4"
ln -s ../u/d "$U/d/sub/up"; ln -s . "$U/d/dot"; ln -s "$U/d" "$U/t/abs"; ln -s 'a b' "$U/t/rel"
ln -s "$U/l1" "$U/l5"; ln -s ../../t "$U/t/sub/cycle"
for i in $(seq 1 300); do printf '%s\n' "$i" > "$U/big/f$i"; done
prev="$U/d/f"; for i in $(seq 1 41); do ln -s "$prev" "$U/c$i"; prev="$U/c$i"; done
printf 'no\n' > "$U/locked/no"; chmod 000 "$U/locked/no"; mkdir "$U/t2"; cp -R "$U/t/." "$U/t2/"
mkdir "$U/t2/closed"; printf 'c\n' > "$U/t2/closed/c"; chmod 000 "$U/t2/closed"

PATHS=("" . .. / // ///tmp//x "$U" "$U/" "$U//d///f" "$U/d/" "$U/d/.." "$U/d/f/" "$U/l1" "$U/l1/"
       "$U/l1/.." "$U/l2" "$U/l3" "$U/l4" "$U/l5" "$U/d/sub/up" "$U/d/sub/up/f" "$U/d/dot" "$U/d/dot/dot/f"
       "$U/missing" "$U/missing/x" "$U/nl"$'\n' "$U/nl"$'\n'/z "$U/c40" "$U/c41" "$U/t2/closed/c"
       "$U/odd/new"$'\n'line "$U/odd/-dash" d/f l1 l2 missing "d/sub/up/../f")
BOUNDS=("" "$U" "$U/d" "$U/t" "$U/missing" "$U/l1" "$U/d/f" "d")
TREES=("$U/t" "$U/t2" "$U/big" "$U/odd" "$U/locked" "$U/d/sub" "$U/nl"$'\n' "$U/empty" t "$U/l1")
EXCLS=("" sub "sub/b.txt,x" "a," "," ",," $'a\nsub' "sub/" "su" "a,,sub" '*' "sub,rel,abs")
mkdir "$U/empty"

unit_transcript() { # <lib-dir> [portable]
  ( cd "$U" && U="$U" AFK_HASH_FORCE_PORTABLE="${2:-}" bash -c '
    set -uo pipefail
    . "$1/afk-common.sh"; . "$1/afk-inventory.sh"; shift
    q() { local o rc; o="$("$@" 2>/dev/null)"; rc=$?; printf "%s|%q\n" "$rc" "$o"; }
    n=$1; shift; paths=("${@:1:n}"); shift "$n"
    n=$1; shift; bounds=("${@:1:n}"); shift "$n"
    n=$1; shift; trees=("${@:1:n}"); shift "$n"
    excls=("$@")
    guards() { # <path>
      for w in file dir link; do for b in "${bounds[@]}"; do for c in "" "$U" "$U/d/sub"; do
        q afk_path_guard "$1" "$w" "$b" "$c"
      done; done; done
    }
    for p in "${paths[@]}"; do
      q afk_realpath "$p"; q afk_resolve_boundary "$p"; q afk_sha256_file "$p"; q afk_encode_path "$p"
      guards "$p"
      for e in "${excls[@]}"; do q afk_excluded "${p#"$U"/}" "$e"; done
    done
    # Again with every boundary already resolved in THIS shell, so each check
    # below runs against a warm memo (the baseline has none) and must agree.
    for b in "${bounds[@]}" "$U/d/sub"; do afk_path_guard "$U/d/f" file "$b" "$b" >/dev/null; done
    for p in "${paths[@]:0:16}"; do guards "$p"; done
    # A boundary symlink repointed, then removed, after the memo was warmed:
    # the baseline re-resolves every time, so the memo must too.
    ln -sfn "$U/t" "$U/bl"; afk_path_guard "$U/t/a" file "$U/bl" "" >/dev/null
    q afk_path_guard "$U/t/a" file "$U/bl" ""
    ln -sfn "$U/d" "$U/bl"; q afk_path_guard "$U/t/a" file "$U/bl" ""
    rm -f "$U/bl"; q afk_path_guard "$U/t/a" file "$U/bl" ""
    # The recorded identity, per manifest text, called in THIS shell so the
    # map is built once and reused for every id (the baseline has no map).
    for m in "{\"components\":{\"a\":{\"identity\":\"x\"},\"b\":{\"identity\":7},\"c\":null,\"q'\''\":{\"identity\":\"sq\"}}}" \
             "{\"components\":{\"a\":{\"identity\":\"x\"}}} {\"components\":{\"a\":{\"identity\":\"y\"}}}" \
             "" null "[]" "\"s\"" "{\"components\":[1]}" "{\"components\":{\"a\":\"str\"}}" \
             "{\"components\":{\"a\":{\"identity\":\"x\\n\\n\"}}}" "{\"components\":{\"a\":{\"identity\":\"x\\u0000y\"}}}" \
             "{\"components\":{\"a\":{\"identity\":\"1\"},\"a\":{\"identity\":\"2\"}}}" "{\"components\":{}}" "{}"; do
      AFK_MANIFEST_JSON="$m"
      for id in a b c "q'\''" z ""; do
        afk_manifest_component_identity "$id" 2>/dev/null; printf "rc=%s\n" "$?"
      done
    done
    for t in "${trees[@]}"; do
      q afk_tree_find_escaping_symlink "$t"
      for e in "${excls[@]}"; do q afk_tree_identity "$t" "$e"; done
    done
    printf "stdin: "; printf "abc" | afk_sha256_stdin; printf "string: %s\n" "$(afk_sha256_string "")"
    printf "END\n"
  ' _ "$1" "${#PATHS[@]}" "${PATHS[@]}" "${#BOUNDS[@]}" "${BOUNDS[@]}" \
          "${#TREES[@]}" "${TREES[@]}" "${EXCLS[@]}" ) 2>&1
}

printf '\n\033[1mprimitives (direct calls)\033[0m\n'
U_OLD="$(unit_transcript "$TMPROOT/k-baseline/lib")"
if [[ "$U_OLD" != *$'\nEND' ]] || (( $(wc -l <<<"$U_OLD") < 4000 )); then
  bad "primitive driver ran to completion" "$(tail -3 <<<"$U_OLD")"
fi
for mode in "" 1; do
  label="primitives${mode:+ (portable hashing)}: $(wc -l <<<"$U_OLD") results identical"
  # Both sides go through the same $(…) capture, so bytes it cannot hold (a
  # NUL) are dropped identically instead of reading as a difference.
  U_NEW="$(unit_transcript "$KIT_ROOT/lib" "$mode")"
  if d="$(diff <(printf '%s\n' "$U_OLD") <(printf '%s\n' "$U_NEW"))"; then
    ok "$label"; else bad "$label" "$d"; fi
done
chmod 755 "$U/t2/closed"

# Candidate only: taking the lock drops the boundary memo and the manifest map
# (the baseline has neither), so every check under the lock resolves again.
LOCK_CASE="$(bash -c 'set -uo pipefail
  for l in common source inventory commands plan mutate; do . "$1/afk-$l.sh"; done
  AFK_STATE_DIR="$2/lock-state"; AFK_LOCK_DIR="$2/lock-state/lock"
  afk_path_guard "$2/t/a" file "$2/t" "" >/dev/null
  AFK_MANIFEST_JSON="{}"; afk_manifest_component_identity x >/dev/null
  before="${#AFK_BOUNDARY_MEMO_KEYS[@]} $AFK_MANIFEST_MAP_STATE"
  afk_lock_acquire; rc=$?
  printf "%s|%s|%s %s" "$before" "$rc" "${#AFK_BOUNDARY_MEMO_KEYS[@]}" "$AFK_MANIFEST_MAP_STATE"
  afk_lock_release' _ "$KIT_ROOT/lib" "$U" 2>&1)"
if [[ "$LOCK_CASE" == "1 mapped|0|0 none" ]]; then ok "afk_lock_acquire drops the boundary memo and the manifest map"
else bad "afk_lock_acquire drops the boundary memo and the manifest map" "$LOCK_CASE"; fi

# Candidate only (AD-19, AC-2/AC-4): a pass fills the whole ledger or leaves
# none, a binding is never computed over a partial one, and a cached
# canonical identity survives the lock-time recheck only while every source
# entry's stat (not merely Git's view of it) holds still.
LR="$TMPROOT/ledger"; mkdir -p "$LR/home"; make_checkout "$LR/kit"
LEDGER_CASE="$(HOME="$LR/home" bash -c 'set -uo pipefail
  for l in common source inventory commands plan mutate; do . "$1/afk-$l.sh"; done
  AFK_KIT_ROOT="$2"; AFK_SKILLS_HOME="$HOME/s"; AFK_CLAUDE_HOME="$HOME/c"; AFK_CODEX_HOME="$HOME/x"
  AFK_MANIFEST="$HOME/state.json"; AFK_CO_MANAGED_INPUTS=(files)
  f=files/codex-AGENTS.md
  afk_observation_pass O1; full="$?:$AFK_OBL_STATE:$AFK_OBL_POINT"
  n=0; eval "orig() $(declare -f afk_observe_component | tail -n +2)"
  afk_observe_component() { n=$((n + 1)); (( n < 3 )) || return 1; orig "$@"; }
  afk_observation_pass O2; part="$?:$AFK_OBL_STATE:${#AFK_OBL[@]}"
  afk_plan_binding_compute O1 reuse; bind="$?:$AFK_PLAN_BINDING"
  afk_observation_restore afk-runtime-bin; rest="$?"
  afk_canonical_enable
  afk_canonical_identity_v a MANAGED_COPY_FILE "$f" ""
  afk_canonical_recheck; afk_canonical_identity_v b MANAGED_COPY_FILE "$f" ""
  # An edit Git is told not to see: only the stat walk can notice it.
  git -C "$2" update-index --assume-unchanged "$f"; printf "two\n" > "$2/$f"
  afk_canonical_recheck; afk_canonical_identity_v c MANAGED_COPY_FILE "$f" ""
  canon="$AFK_CANON_STATE:$([[ "$a" == "$b" && "$b" != "$c" && -n "$a" ]] && echo moved)"
  printf "%s|%s|%s|%s|%s" "$full" "$part" "$bind" "$rest" "$canon"' _ "$KIT_ROOT/lib" "$LR/kit" 2>&1)"
if [[ "$LEDGER_CASE" == "0:complete:O1|1:none:0|1:{}|1|on:moved" ]]; then
  ok "a partial observation pass leaves no ledger to bind, and a checkout edited behind Git's back is re-hashed"
else bad "a partial observation pass leaves no ledger to bind, and a checkout edited behind Git's back is re-hashed" "$LEDGER_CASE"; fi

TIMES="$TMPROOT/times"
for fx in $FIXTURES; do
  [[ "$fx" != none ]] || continue
  printf '\n\033[1mfixture: %s\033[0m\n' "$fx"
  if [[ "$fx" == unreadable ]] && (( EUID == 0 )); then printf '  root reads mode-000 files; skipped\n'; continue; fi
  build_fixture "$fx" || continue
  cp -a "$FX" "$TMPROOT/golden-$fx"
  # The identity an owner would approve: the baseline's own adopt plan.
  restore_fixture "$fx"; run_cli baseline "$TMPROOT/approval-$fx" adopt --json --plan
  APPROVAL="$(jq -r '.operation.plan_identity // "none"' "$TMPROOT/approval-$fx.stdout" 2>/dev/null)"
  for verb in $VERBS; do
    mapfile -t args < <(verb_args "$verb")
    for side in baseline candidate portable; do
      restore_fixture "$fx"
      kit=candidate; [[ "$side" == baseline ]] && kit=baseline
      t0="$EPOCHREALTIME"
      if [[ "$side" == portable ]]; then
        AFK_HASH_FORCE_PORTABLE=1 run_cli "$kit" "$TMPROOT/$fx-$verb-$side" "${args[@]}"
      else
        run_cli "$kit" "$TMPROOT/$fx-$verb-$side" "${args[@]}"
      fi
      printf '%s %s %s %s\n' "$fx" "$verb" "$side" "$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.2f", b-a}')" >> "$TIMES"
      host_state > "$TMPROOT/$fx-$verb-$side.host"
    done
    compare_run "$fx $verb" "$TMPROOT/$fx-$verb-baseline" "$TMPROOT/$fx-$verb-candidate"
    compare_run "$fx $verb (portable hashing)" "$TMPROOT/$fx-$verb-baseline" "$TMPROOT/$fx-$verb-portable"
    check_points "$fx $verb" "$TMPROOT/$fx-$verb-candidate"
  done
done

printf '\n\033[1mdrift between safety boundaries\033[0m\n'
while IFS=: read -r fx verb point change want; do
  [[ -n "$fx" && "$fx" != none ]] || continue
  case " $FIXTURES " in *" $fx "*) : ;; *) continue ;; esac
  [[ -d "$TMPROOT/golden-$fx" ]] || continue
  mapfile -t args < <(verb_args "$verb")
  label="$fx $verb, $change changed at the $point boundary"
  for side in baseline candidate; do
    restore_fixture "$fx"
    ENTRY=afk-equiv-drift AFK_EQUIV_DRIFT="$point:$change" \
      run_cli "$side" "$TMPROOT/drift-$fx-$point-$change-$side" "${args[@]}"
    host_state > "$TMPROOT/drift-$fx-$point-$change-$side.host"
  done
  compare_run "$label" "$TMPROOT/drift-$fx-$point-$change-baseline" "$TMPROOT/drift-$fx-$point-$change-candidate"
  check_points "$label" "$TMPROOT/drift-$fx-$point-$change-candidate"
  got="$(jq -r '"\(.operation.result)/\(.operation.reason)"' "$TMPROOT/drift-$fx-$point-$change-candidate.stdout" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then ok "$label: refused as $want"
  else bad "$label: refused as $want" "got $got"; fi
done <<< "$DRIFTS"

# An observation pass that cannot complete (AD-19). The candidate reports it
# as a blocking component-inventory component, so the installation can never
# read CURRENT, and every mutation still refuses exactly as the baseline does.
# The baseline has no equivalent report: with an unenumerable inventory it
# listed zero components and called the installation CURRENT (the gap this
# closes), and it never observed through afk_observe_component to report, so
# an unobservable component there still yields a full report built from the
# other primitives. What must match byte for byte is therefore stderr and the
# host tree for every verb, and the exit code and refusal for every mutation:
# the whole operation block when the inventory cannot be enumerated, and its
# result and reason when one component cannot be observed (the plan identity
# digests the report, which necessarily differs).
printf '\n\033[1mobservation pass that cannot complete\033[0m\n'
for fc in ${AFK_EQUIV_FAULTS:-clean:table drift:table drift:observe}; do
  fx="${fc%%:*}" fault="${fc#*:}"
  case " $FIXTURES " in *" $fx "*) : ;; *) continue ;; esac
  [[ -d "$TMPROOT/golden-$fx" ]] || continue
  for verb in status verify plan update; do
    mapfile -t args < <(verb_args "$verb")
    label="$fx $verb, $fault fault"; p="$TMPROOT/fault-$fx-$fault-$verb"
    for side in baseline candidate; do
      restore_fixture "$fx"
      ENTRY=afk-equiv-fault AFK_EQUIV_FAULT="$fault" run_cli "$side" "$p-$side" "${args[@]}"
      host_state > "$p-$side.host"
    done
    compare_run "$label" "$p-baseline" "$p-candidate" "stderr host"
    if [[ "$verb" == plan || "$verb" == update ]]; then
      compare_run "$label" "$p-baseline" "$p-candidate" "rc"
      for side in baseline candidate; do
        if [[ "$fault" == table ]]; then jq -S '.operation' "$p-$side.stdout"
        else jq -c '[.operation.result, .operation.reason]' "$p-$side.stdout"; fi > "$p-$side.op" 2>&1
      done
      compare_run "$label" "$p-baseline" "$p-candidate" "op"
    fi
    got="$(jq -c '[.installed.state, ([.components[] | select(.id == "component-inventory"
            and .state == "BROKEN" and .severity == "blocking" and .execution_critical)] | length)]' \
            "$p-candidate.stdout" 2>/dev/null)"
    if [[ "$got" == '["BROKEN",1]' ]]; then ok "$label: reported BROKEN with a blocking component-inventory"
    else bad "$label: reported BROKEN with a blocking component-inventory" "got $got"; fi
  done
done

printf '\nwall seconds (fixture verb side):\n'; column -t "$TIMES" 2>/dev/null || cat "$TIMES"
[[ -z "${AFK_EQUIV_OBSLOG:-}" ]] || { mkdir -p "$AFK_EQUIV_OBSLOG" && cp "$TMPROOT"/obs/*.log "$AFK_EQUIV_OBSLOG"/ 2>/dev/null; }
if [[ -n "${AFK_EQUIV_KEEP:-}" ]]; then
  mkdir -p "$AFK_EQUIV_KEEP" && cp "$TMPROOT"/*.rc "$TMPROOT"/*.stdout "$TMPROOT"/*.stderr "$TMPROOT"/*.host "$TIMES" "$AFK_EQUIV_KEEP"/ 2>/dev/null
fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
