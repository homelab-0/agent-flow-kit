#!/usr/bin/env bash
# dispatch-secret-scan-tests.sh — AFK-SEC-1 (AD-14, F15): proves
# scan_worktree_for_secrets never lets a resolved secret reach the gates
# unnoticed, and never lets the secret itself reach argv, a log, or output.
#
# dispatch.sh is sourced exactly as tests/lifecycle-dispatch-tests.sh does
# (its main() is guarded by the BASH_SOURCE/0 check), inside a temporary real
# git repository so every git-backed branch (tracked diff, untracked file,
# gitignored file) is reached for real.
#
# Usage: tests/dispatch-secret-scan-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"

export GIT_AUTHOR_NAME="afk-test" GIT_AUTHOR_EMAIL="afk@test.invalid"
export GIT_COMMITTER_NAME="afk-test" GIT_COMMITTER_EMAIL="afk@test.invalid"

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  FAIL=$((FAIL + 1))
}
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq()       { if [[ "$2" == "$3"   ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_absent()   { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain: $3"; fi; }

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

new_repo() { # <name> -> prints the repo path
  local repo="$TMPROOT/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add seed.txt
  git -C "$repo" commit -q -m seed
  printf '%s' "$repo"
}

# Feeds the given secrets to scan_worktree_for_secrets through fd 9, exactly
# as dispatch.sh's main() does with `exec 9< <(...)`, then closes it. Prints
# scanner stdout, and the scanner's exit code is this function's exit code.
run_scan() { # <worktree> <secret>...
  local worktree="$1"; shift
  bash -c '
    . "$1"; shift
    worktree="$1"; shift
    exec 9< <(printf "%s\n" "$@")
    scan_worktree_for_secrets "$worktree" 9
    rc=$?
    exec 9<&-
    exit "$rc"
  ' _ "$DISPATCH" "$worktree" "$@"
}

head1 "1. Clean diff"
repo="$(new_repo clean)"
out="$(run_scan "$repo" "abcdefghijkl-not-present")"; rc=$?
assert_eq "clean diff returns 0" "$rc" "0"
assert_eq "clean diff prints nothing" "$out" ""

head1 "2. Secret in a modified tracked file"
repo="$(new_repo tracked)"
secret="sk-live-abcdefghijklmnop"
printf 'token=%s\n' "$secret" >> "$repo/seed.txt"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "modified tracked file returns 3" "$rc" "3"
assert_eq "modified tracked file is reported" "$out" "seed.txt"

head1 "3. Secret in a new untracked file"
repo="$(new_repo untracked)"
secret="sk-live-untrackedsecret1"
printf 'token=%s\n' "$secret" > "$repo/new-file.txt"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "untracked file returns 3" "$rc" "3"
assert_eq "untracked file is reported" "$out" "new-file.txt"

head1 "4. Secret in a gitignored file is not scanned"
repo="$(new_repo ignored)"
secret="sk-live-ignoredsecret123"
printf '*.ignored\n' > "$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -q -m gitignore
printf 'token=%s\n' "$secret" > "$repo/leak.ignored"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "gitignored file returns 0" "$rc" "0"
assert_eq "gitignored file is never reported" "$out" ""

head1 "5. Secret shorter than 12 characters is ignored"
repo="$(new_repo short)"
short_secret="short1secret"
short_secret="${short_secret:0:11}"
printf 'token=%s\n' "$short_secret" > "$repo/new-file.txt"
out="$(run_scan "$repo" "$short_secret")"; rc=$?
assert_eq "sub-12-char secret returns 0" "$rc" "0"
assert_eq "sub-12-char secret is never reported" "$out" ""

head1 "6. The secret never appears in output, and never reaches the scanner's argv"
repo="$(new_repo argv)"
secret="sk-live-argvcaptureproof"
printf 'token=%s\n' "$secret" > "$repo/new-file.txt"
FAKEBIN="$TMPROOT/fakebin"; mkdir -p "$FAKEBIN"
ARGV_LOG="$TMPROOT/grep-argv.log"
REAL_GREP="$(command -v grep)"
cat > "$FAKEBIN/grep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$ARGV_LOG"
exec "$REAL_GREP" "\$@"
STUB
chmod +x "$FAKEBIN/grep"
out="$(PATH="$FAKEBIN:$PATH" ARGV_LOG="$ARGV_LOG" bash -c '
  . "$1"; shift
  worktree="$1"; shift
  exec 9< <(printf "%s\n" "$@")
  scan_worktree_for_secrets "$worktree" 9
  rc=$?
  exec 9<&-
  exit "$rc"
' _ "$DISPATCH" "$repo" "$secret")"; rc=$?
assert_eq "captured secret still returns 3" "$rc" "3"
assert_eq "captured secret is reported by path only" "$out" "new-file.txt"
assert_absent "the scanner's own output never carries the secret" "$out" "$secret"
if [[ -f "$ARGV_LOG" ]]; then
  assert_absent "the secret was never passed to grep as an argument" "$(cat "$ARGV_LOG")" "$secret"
else
  bad "grep argv was captured" "no $ARGV_LOG written — stub never ran"
fi

head1 "7. Two secrets, only the second matches"
repo="$(new_repo two)"
secret_a="sk-live-firstsecretvalue"
secret_b="sk-live-secondsecretvalu"
printf 'token=%s\n' "$secret_b" > "$repo/new-file.txt"
out="$(run_scan "$repo" "$secret_a" "$secret_b")"; rc=$?
assert_eq "only the matching secret still catches the file" "$rc" "3"
assert_eq "the matched file is reported once" "$out" "new-file.txt"

head1 "8. Evasion shapes: staged, renamed, new directory, binary, unusual name"
secret="sk-live-evasionshapes1234"
repo="$(new_repo staged)"
printf 'x %s\n' "$secret" > "$repo/staged.txt"; git -C "$repo" add staged.txt
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "staged-but-uncommitted file is caught" "$rc:$out" "3:staged.txt"
repo="$(new_repo renamed)"
git -C "$repo" mv seed.txt moved.txt; printf '%s\n' "$secret" >> "$repo/moved.txt"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "renamed file is caught under its new name" "$rc:$out" "3:moved.txt"
repo="$(new_repo newdir)"
mkdir -p "$repo/a/b"; printf '%s\n' "$secret" > "$repo/a/b/deep.txt"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "file in a new directory is caught" "$rc:$out" "3:a/b/deep.txt"
repo="$(new_repo binary)"
printf '\000\001%s\000' "$secret" > "$repo/blob.bin"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "binary file is caught" "$rc:$out" "3:blob.bin"
repo="$(new_repo unicode)"
printf '%s\n' "$secret" > "$repo/café \"q\".txt"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "non-ASCII/quoted file name is caught, unquoted" "$rc:$out" "3:café \"q\".txt"

head1 "9. Scanning from a subdirectory still covers the whole tree"
repo="$(new_repo subdir)"
mkdir -p "$repo/sub" "$repo/other"; printf 'x\n' > "$repo/sub/keep.txt"
git -C "$repo" add sub; git -C "$repo" commit -q -m sub
printf '%s\n' "$secret" > "$repo/other/leak.txt"
out="$(run_scan "$repo/sub" "$secret")"; rc=$?
assert_eq "a leak outside the cwd subtree is caught, root-relative" "$rc:$out" "3:other/leak.txt"

head1 "10. Symlinks are never followed out of the worktree"
repo="$(new_repo symlink)"
printf '%s\n' "$secret" > "$TMPROOT/outside-secret.txt"
ln -s "$TMPROOT/outside-secret.txt" "$repo/link.txt"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "a symlink to an outside file holding the secret is not followed" "$rc:$out" "0:"
repo="$(new_repo symlink-target)"
ln -s "prefix-$secret" "$repo/named-link"
out="$(run_scan "$repo" "$secret")"; rc=$?
assert_eq "a symlink whose target TEXT carries the secret is caught" "$rc:$out" "3:named-link"

head1 "11. A tree that cannot be enumerated is incomplete, never clean"
notrepo="$TMPROOT/not-a-repo"; mkdir -p "$notrepo"
out="$(run_scan "$notrepo" "$secret")"; rc=$?
assert_eq "outside a git repository returns 4" "$rc:$out" "4:"

# Same as run_scan, but passes a <base> commit through as the scanner's third
# argument — exercising the AD-14 gap fix: a base recorded before the worker
# ran, rather than "HEAD" read after.
run_scan_base() { # <worktree> <base> <secret>...
  local worktree="$1" base="$2"; shift 2
  bash -c '
    . "$1"; shift
    worktree="$1"; shift
    base="$1"; shift
    exec 9< <(printf "%s\n" "$@")
    scan_worktree_for_secrets "$worktree" 9 "$base"
    rc=$?
    exec 9<&-
    exit "$rc"
  ' _ "$DISPATCH" "$worktree" "$base" "$@"
}

head1 "12. A secret the worker COMMITS during the cycle is still caught (AD-14 gap fix)"
repo="$(new_repo committed-during-cycle)"
base="$(git -C "$repo" rev-parse HEAD)"
secret="sk-live-committedmidcycle1"
printf 'token=%s\n' "$secret" > "$repo/leaked.txt"
git -C "$repo" add leaked.txt
git -C "$repo" commit -q -m "worker commit with a secret"
out_head="$(run_scan "$repo" "$secret")"; rc_head=$?
assert_eq "diffing against post-cycle HEAD alone sees nothing (the gap)" "$rc_head:$out_head" "0:"
out_base="$(run_scan_base "$repo" "$base" "$secret")"; rc_base=$?
assert_eq "diffing against the pre-cycle base still catches it" "$rc_base:$out_base" "3:leaked.txt"

head1 "13. A secret committed then removed by a later commit is clean at the tip"
repo="$(new_repo committed-then-removed)"
base="$(git -C "$repo" rev-parse HEAD)"
secret="sk-live-committedthenremov"
printf 'token=%s\n' "$secret" > "$repo/leaked.txt"
git -C "$repo" add leaked.txt
git -C "$repo" commit -q -m "worker commit with a secret"
rm "$repo/leaked.txt"
git -C "$repo" add leaked.txt
git -C "$repo" commit -q -m "worker removes the secret"
out="$(run_scan_base "$repo" "$base" "$secret")"; rc=$?
assert_eq "clean at the tip: the file no longer exists to be read" "$rc:$out" "0:"

head1 "14. Result projection: SECRET_IN_DIFF forces gates_failed; clean shape unchanged"
proj() { bash -c '. "$1"; shift; attempt_result_projection "$@"' _ "$DISPATCH" "$@"; }
assert_eq "no reason keeps the pre-existing shape" "$(proj "" true 0 false)" \
  '{"status":"done","launch":{"harness_exit":0}}'
assert_eq "SECRET_IN_DIFF overrides a continuation and carries paths only" \
  "$(proj continuation_required true 0 false SECRET_IN_DIFF '["a.txt"]')" \
  '{"status":"gates_failed","launch":{"harness_exit":0},"failure_reason":"SECRET_IN_DIFF","paths":["a.txt"]}'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
