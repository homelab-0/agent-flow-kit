#!/usr/bin/env bash
# Attack 4 (AC-5) — native byte-identity. Source master's dispatch.sh builders
# and HEAD's in separate shells and compare their output for identical inputs.
# Control: a deliberately perturbed input must make the same comparison FAIL,
# so a vacuous "both empty" pass cannot be mistaken for identity.
set -uo pipefail
WT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git -C "$WT" show master:files/model-router/scripts/dispatch.sh > "$TMP/master.sh"
cp "$WT/files/model-router/scripts/dispatch.sh" "$TMP/head.sh"

emit() { # <script> <builder> <args...>   ($0 != BASH_SOURCE so main() stays guarded)
  bash -c 'set -uo pipefail; . "$1"; shift; "$@"' _emit "$@"
}

fail=0
chk() { # <label> <expected-relation eq|ne> <a> <b>
  local l="$1" rel="$2" a="$3" b="$4"
  [[ -n "$a" ]] || { echo "FAIL $l — LHS empty, the probe itself is broken"; fail=1; return; }
  if [[ "$rel" == eq ]]; then
    if [[ "$a" == "$b" ]]; then echo "PASS $l"; else echo "FAIL $l"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b"); fail=1; fi
  else
    if [[ "$a" != "$b" ]]; then echo "PASS $l"; else echo "FAIL $l"; fail=1; fi
  fi
}

A=(/home/op /usr/bin:/bin op /wt/S.md.prompt claude-opus-5 high /wt/S.md.claude-result.json /wt/agents/dev.md)
B=(/home/op /usr/bin:/bin op /wt/S.md.prompt claude-opus-5 high /wt/S.md.claude-result.json "")

chk "build_claude_command (with persona) byte-identical to master" eq \
  "$(emit "$TMP/master.sh" build_claude_command "${A[@]}")" "$(emit "$TMP/head.sh" build_claude_command "${A[@]}")"
chk "build_claude_command (no persona) byte-identical to master" eq \
  "$(emit "$TMP/master.sh" build_claude_command "${B[@]}")" "$(emit "$TMP/head.sh" build_claude_command "${B[@]}")"
chk "build_codex_command byte-identical to master" eq \
  "$(emit "$TMP/master.sh" build_codex_command /wt/S.md.prompt gpt-5.6-sol xhigh)" \
  "$(emit "$TMP/head.sh"   build_codex_command /wt/S.md.prompt gpt-5.6-sol xhigh)"

# CONTROL — the comparison must be able to see a difference.
chk "CONTROL: a perturbed effort IS detected as different" ne \
  "$(emit "$TMP/master.sh" build_claude_command "${A[@]}")" \
  "$(emit "$TMP/head.sh" build_claude_command /home/op /usr/bin:/bin op /wt/S.md.prompt claude-opus-5 medium /wt/S.md.claude-result.json /wt/agents/dev.md)"

echo "--- the native command text (HEAD) ---"
emit "$TMP/head.sh" build_claude_command "${A[@]}"; echo
exit $fail
