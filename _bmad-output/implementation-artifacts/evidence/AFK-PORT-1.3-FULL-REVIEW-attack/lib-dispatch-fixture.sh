#!/usr/bin/env bash
# lib-dispatch-fixture.sh — the dispatch-monitor fixture, lifted from
# tests/lifecycle-dispatch-tests.sh so the attacks below run against exactly the
# model the story's own gate accepts.
#
# Sourced, never executed on its own.

set -uo pipefail

KIT_ROOT="${AFK_ATTACK_KIT_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
AFK="$KIT_ROOT/bin/agent-flow-kit"
if [[ ! -f "$AFK" ]]; then
  printf 'attack fixture: %s not found — set AFK_ATTACK_KIT_ROOT\n' "$AFK" >&2
  exit 2
fi

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

export GIT_AUTHOR_NAME="afk-attack" GIT_AUTHOR_EMAIL="afk@attack.invalid"
export GIT_COMMITTER_NAME="afk-attack" GIT_COMMITTER_EMAIL="afk@attack.invalid"

say()  { printf '  %s\n' "$*"; }
head1(){ printf '\n== %s\n' "$*"; }

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
  printf 'policy line one\n' > "$d/files/claude-global-CLAUDE.md"
  printf 'codex guidance v1\n' > "$d/files/codex-AGENTS.md"
  git init -q "$d" >/dev/null 2>&1
  git -C "$d" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
  git_commit_all "$d" "canonical v1"
}

CHECKOUT="$TMPROOT/checkout"
BIN="$TMPROOT/bin"
mkdir -p "$CHECKOUT" "$BIN"
make_checkout "$CHECKOUT"

# --- the Orca stub, byte-for-byte the one tests/lifecycle-dispatch-tests.sh uses
STUB_TERMS="$TMPROOT/orca-terminals.txt"
STUB_CLOSED="$TMPROOT/orca-closed.txt"
: > "$STUB_TERMS"; : > "$STUB_CLOSED"
export STUB_TERMS STUB_CLOSED

cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "terminal list")
    first=1
    printf '{"terminals":['
    while read -r h s; do
      [[ -n "$h" ]] || continue
      if grep -q -x -F -- "$h" "$STUB_CLOSED" 2>/dev/null; then continue; fi
      if (( first )); then first=0; else printf ','; fi
      printf '{"handle":"%s","status":"%s"}' "$h" "$s"
    done < "$STUB_TERMS"
    printf ']}\n'
    exit 0 ;;
  "terminal close")
    shift 2
    handle=""; durable=0
    while (( $# )); do
      case "$1" in
        --handle)  handle="${2:-}"; shift 2 ;;
        --durable) durable=1; shift ;;
        *)         shift ;;
      esac
    done
    if (( durable )) && [[ -n "$handle" ]]; then
      printf '%s\n' "$handle" >> "$STUB_CLOSED"
      printf '{"ok":true,"closed":true,"durable":true}\n'
    else
      printf '{"ok":true,"closed":true,"durable":false}\n'
    fi
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$BIN/orca"

terminal_add()    { printf '%s %s\n' "$1" "$2" >> "$STUB_TERMS"; }
terminal_listed() { # <handle> -> 0 when Orca still knows about it
  PATH="$BIN:$PATH" orca terminal list --json </dev/null 2>/dev/null \
    | jq -e --arg h "$1" '[.terminals[] | select(.handle == $h)] | length > 0' >/dev/null 2>&1
}

HOMEDIR=""; STATE=""; WATCH=""; INBOX=""; RESULTS=""
new_scenario() { # <name>
  HOMEDIR="$TMPROOT/sc-$1/home"
  STATE="$HOMEDIR/.local/state/agent-flow-kit"
  WATCH="$STATE/dispatch/watch"
  INBOX="$STATE/dispatch/inbox"
  RESULTS="$STATE/dispatch/results"
  mkdir -p "$HOMEDIR"
}

RUN_OUT=""; RUN_ERR=""; RUN_RC=0
run_afk() { # <args...>
  RUN_OUT="$(env PATH="$BIN:$PATH" HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             STUB_TERMS="$STUB_TERMS" STUB_CLOSED="$STUB_CLOSED" \
             bash "$AFK" "$@" </dev/null 2>"$TMPROOT/stderr")"
  RUN_RC=$?
  RUN_ERR="$(cat "$TMPROOT/stderr" 2>/dev/null)"
}

jget() { printf '%s' "$RUN_OUT" | jq -r "$1"; }
rec()  { jq -r "$2" "$WATCH/$1.json" 2>/dev/null; }

descriptor() { # <id> <task> <terminal|-> <worktree|-> <branch|-> <repo|-> <base|-> <remote|->
               # <pr_merged> <disposable> <remote_auth> [owned]
  jq -nc --arg id "$1" --arg task "$2" --arg term "$3" --arg wt "$4" \
     --arg br "$5" --arg repo "$6" --arg base "$7" --arg remote "$8" \
     --argjson merged "$9" --argjson disposable "${10}" --argjson auth "${11}" \
     --argjson owned "${12:-true}" '
    {dispatch_id: $id, task_id: $task,
     terminal: {handle: (if $term == "-" then "" else $term end), owned: $owned},
     worktree: {path: (if $wt == "-" then "" else $wt end), owned: $owned},
     branch: {name: (if $br == "-" then "" else $br end),
              repo: (if $repo == "-" then "" else $repo end),
              base: (if $base == "-" then "" else $base end),
              remote: (if $remote == "-" then "" else $remote end),
              owned: $owned, disposable: $disposable, pr_merged: $merged,
              remote_delete_authorized: $auth}}'
}

register() { # <descriptor json>
  printf '%s' "$1" > "$TMPROOT/descriptor.json"
  run_afk monitor --json --register "$TMPROOT/descriptor.json"
}

deliver() { # <delivery id> <dispatch id> <kind> <status>
  mkdir -p "$INBOX"
  jq -nc --arg d "$1" --arg t "$2" --arg k "$3" --arg s "$4" \
    '{schema_version: "1.0", delivery_id: $d, dispatch_id: $t, kind: $k,
      result: {status: $s, summary: "one bounded worker result",
               evidence: ["evidence/one.log"]}}' > "$INBOX/$1.json"
}

new_repo() { # <dir>
  git init -q "$1" >/dev/null 2>&1
  git -C "$1" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
  printf 'base\n' > "$1/README"
  git_commit_all "$1" "base"
}

VERDICT=0
fails() { printf '\n  >>> %s\n' "$*"; VERDICT=1; }
