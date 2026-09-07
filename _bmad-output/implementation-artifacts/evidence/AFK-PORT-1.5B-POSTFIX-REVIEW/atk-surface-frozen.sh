#!/usr/bin/env bash
# Frozen texts, diff surface, commit hygiene.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$ROOT"
echo "=== A. the two frozen launch command texts vs master ==="
grep -n 'launch_command_text\|LAUNCH_CMD\|claude_launch\|codex_launch' files/model-router/scripts/dispatch.sh | head -20
echo "--- byte comparison of the launch-text builders, master vs HEAD ---"
git show master:files/model-router/scripts/dispatch.sh > /tmp/atk-master-dispatch.sh
for fn in build_claude_command build_codex_command; do
  a="$(sed -n "/^$fn() {/,/^}/p" /tmp/atk-master-dispatch.sh | sha256sum | cut -d' ' -f1)"
  b="$(sed -n "/^$fn() {/,/^}/p" files/model-router/scripts/dispatch.sh | sha256sum | cut -d' ' -f1)"
  printf '%-24s master=%s head=%s  %s\n' "$fn" "${a:0:12}" "${b:0:12}" \
    "$([[ "$a" == "$b" ]] && echo IDENTICAL || echo DIFFERS)"
done
echo
echo "=== B. does the fix commit touch the launch texts at all? ==="
git diff master e2f3e92 --stat -- files/model-router/scripts/dispatch.sh
git diff 54dfd14 e2f3e92 -- files/model-router/scripts/dispatch.sh | grep -nE '^[-+].*(orca terminal send|--text|launch)' || echo "  no launch-text line in the fix diff"
echo
echo "=== C. diff surface of e2f3e92 ==="
git diff --name-only 54dfd14 e2f3e92
echo
echo "=== D. commit message hygiene (no trailers, no AI attribution) ==="
git log -1 --format='%B' e2f3e92
echo "trailer/attribution scan:"
git log -1 --format='%B' e2f3e92 | grep -inE 'co-authored|generated with|claude|bmad|story|epic|persona|gate' || echo "  clean"
echo
echo "=== E. git diff --check ==="
git diff --check; echo "rc=$?"
git diff master...HEAD --check; echo "range rc=$?"
echo
echo "=== F. working tree state (review must change nothing outside evidence) ==="
git status --porcelain
