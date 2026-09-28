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
# (plus, in stderr only, the source line number in bash's own diagnostics);
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
#   AFK_EQUIV_BASE=<ref>        baseline (default HEAD)
#   AFK_EQUIV_ONLY="a b"        only these fixtures ("none": primitives only)
#   AFK_EQUIV_VERBS="status"    only these verbs (status verify plan adopt update)
#   AFK_EQUIV_KEEP=<dir>        keep every raw output there
# Exit:  0 all identical, 1 any difference.

set -uo pipefail
unset AFK_ORCA_BIN ORCA_CLI_COMMAND AGENT_ROUTER_URL AGENT_ROUTER_TOKEN \
      AGENT_STAMP_VALIDATE_CATALOG_PATH AFK_LIB_DIR AFK_HASH_FORCE_PORTABLE CDPATH

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BASE="${AFK_EQUIV_BASE:-HEAD}"
FIXTURES="${AFK_EQUIV_ONLY:-installed clean ahead drift redirect missing unreadable}"
VERBS="${AFK_EQUIV_VERBS:-status verify plan adopt update}"

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

# --- fixtures (the shapes of tests/lifecycle-mutation-tests.sh) -------------

FX="$TMPROOT/fx" HOMEDIR="$TMPROOT/fx/home" CHECKOUT="$TMPROOT/fx/checkout"

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
  ( cd "$FX" && HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
      bash "$KIT/bin/agent-flow-kit" "$@" >"$out.stdout" 2>"$out.stderr" )
  RUN_RC=$?
  mv "$KIT" "$TMPROOT/k-$side"
  printf '%s\n' "$RUN_RC" > "$out.rc"
}

build_fixture() { # <name>
  rm -rf "$FX"; mkdir -p "$HOMEDIR" "$CHECKOUT"
  make_checkout "$CHECKOUT"
  install_kit "$HOMEDIR" "$CHECKOUT"
  [[ "$1" == installed ]] && return 0
  run_cli baseline "$TMPROOT/build-$1" adopt --json
  [[ "$RUN_RC" == 0 ]] || { bad "fixture $1: baseline adopt established ownership" "exit $RUN_RC"; return 1; }
  case "$1" in
    ahead)
      printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
      printf 'policy line one\npolicy line two\npolicy line three\n' > "$CHECKOUT/files/claude-global-CLAUDE.md"
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
  esac
}

# stderr alone also masks the SOURCE LINE bash prints in its own diagnostics
# ("afk-common.sh: line 122: <path>: Permission denied"): that number moves
# with any edit to the file. The message, the path and the count still match.
compare_run() { # <label> <baseline-prefix> <candidate-prefix>
  local label="$1" a="$2" b="$3" part d re
  for part in rc stdout stderr host; do
    re=''; [[ "$part" != stderr ]] || re='s/(\.sh: line )[0-9]+:/\1N:/'
    if d="$(diff <(mask "$a.$part" | sed -E "$re") <(mask "$b.$part" | sed -E "$re"))"; then :; else
      bad "$label: $part identical" "$d"; return
    fi
  done
  ok "$label: exit $(cat "$a.rc"), JSON, stderr and host state identical"
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

unit_transcript() { # <afk-common.sh> [portable]
  ( cd "$U" && U="$U" AFK_HASH_FORCE_PORTABLE="${2:-}" bash -c '
    set -uo pipefail
    . "$1"; shift
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
U_OLD="$(unit_transcript "$TMPROOT/k-baseline/lib/afk-common.sh")"
if [[ "$U_OLD" != *$'\nEND' ]] || (( $(wc -l <<<"$U_OLD") < 4000 )); then
  bad "primitive driver ran to completion" "$(tail -3 <<<"$U_OLD")"
fi
for mode in "" 1; do
  label="primitives${mode:+ (portable hashing)}: $(wc -l <<<"$U_OLD") results identical"
  if d="$(diff <(printf '%s\n' "$U_OLD") <(unit_transcript "$KIT_ROOT/lib/afk-common.sh" "$mode"))"; then
    ok "$label"; else bad "$label" "$d"; fi
done
chmod 755 "$U/t2/closed"

TIMES="$TMPROOT/times"
for fx in $FIXTURES; do
  [[ "$fx" != none ]] || continue
  printf '\n\033[1mfixture: %s\033[0m\n' "$fx"
  if [[ "$fx" == unreadable ]] && (( EUID == 0 )); then printf '  root reads mode-000 files; skipped\n'; continue; fi
  build_fixture "$fx" || continue
  cp -a "$FX" "$TMPROOT/golden-$fx"
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
  done
done

printf '\nwall seconds (fixture verb side):\n'; column -t "$TIMES" 2>/dev/null || cat "$TIMES"
if [[ -n "${AFK_EQUIV_KEEP:-}" ]]; then
  mkdir -p "$AFK_EQUIV_KEEP" && cp "$TMPROOT"/*.rc "$TMPROOT"/*.stdout "$TMPROOT"/*.stderr "$TMPROOT"/*.host "$TIMES" "$AFK_EQUIV_KEEP"/ 2>/dev/null
fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
