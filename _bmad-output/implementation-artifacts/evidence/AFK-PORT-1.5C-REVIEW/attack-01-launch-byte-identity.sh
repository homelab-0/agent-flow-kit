#!/usr/bin/env bash
# ATTACK 1 — no new launch path, no substitution.
# Extracts every launch-command builder from master and from the branch and
# compares them byte-for-byte; then greps for any route/profile/harness/effort
# field assigned from anything but the stamp.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
BASE=${1:-e76cb95} HEAD_REF=${2:-HEAD}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git show "$BASE:files/model-router/scripts/dispatch.sh"     > "$tmp/base.sh"
git show "$HEAD_REF:files/model-router/scripts/dispatch.sh" > "$tmp/head.sh"
extract() { # <file> <fn>
  awk -v fn="$2" '$0 ~ "^"fn"\\(\\) \\{" {inf=1} inf {print} inf && /^}$/ {exit}' "$1"
}
rc=0
for fn in build_claude_command build_codex_command build_claude_gateway_command orca_launch; do
  extract "$tmp/base.sh" "$fn" > "$tmp/b.$fn"
  extract "$tmp/head.sh" "$fn" > "$tmp/h.$fn"
  if [[ ! -s "$tmp/b.$fn" ]]; then echo "SKIP $fn (absent on $BASE)"; continue; fi
  if cmp -s "$tmp/b.$fn" "$tmp/h.$fn"; then
    echo "PASS $fn byte-identical ($(sha256sum < "$tmp/h.$fn" | cut -c1-16))"
  else
    echo "FAIL $fn DIFFERS"; diff -u "$tmp/b.$fn" "$tmp/h.$fn" | head -40; rc=1
  fi
done
echo "--- new launch entry points introduced by the branch? ---"
newfns=$(comm -13 <(grep -oE '^[a-z_]+\(\)' "$tmp/base.sh" | sort -u) \
                  <(grep -oE '^[a-z_]+\(\)' "$tmp/head.sh" | sort -u))
echo "${newfns:-<none>}"
if grep -qE 'orca (terminal|worker) (create|start|send)' <<<"$(diff "$tmp/base.sh" "$tmp/head.sh" | grep '^>')"; then
  echo "FAIL added code launches a terminal outside orca_launch"; rc=1
else
  echo "PASS no added code launches a terminal"
fi
echo "--- route fields assigned from anything but the stamp (added lines) ---"
if diff "$tmp/base.sh" "$tmp/head.sh" | grep '^>' \
   | grep -E '^\> *(HARNESS|MODEL_PROFILE|NATIVE_MODEL|EFFORT|STAMP_[A-Z_]+)='; then
  echo "FAIL a route field is assigned in added code"; rc=1
else
  echo "PASS no route field is assigned in added code"
fi
echo "--- CONTROL (must FAIL-detect): a deliberately mutated builder ---"
sed 's/--effort/--efort/' "$tmp/head.sh" > "$tmp/mut.sh"
extract "$tmp/mut.sh" build_claude_command > "$tmp/m.fn"
cmp -s "$tmp/b.build_claude_command" "$tmp/m.fn" \
  && { echo "FAIL control: mutation not detected"; rc=1; } \
  || echo "PASS control: the comparison detects a one-character mutation"
exit $rc
