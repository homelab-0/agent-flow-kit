#!/usr/bin/env bash
# catalog-sync-tests.sh — the isolated deterministic gate for
# `agent-flow-kit catalog-sync` (lib/afk-catalog-sync.sh) and the trusted
# catalog resolution order in dispatch.sh and status.
#
# No network: `git ls-remote` and `curl` are stubs that serve a fixture
# "prox-ops" tree from a temp dir, keyed by commit. Every run gets a throwaway
# HOME and state directory.
#
# Usage: tests/catalog-sync-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
POLICY="$KIT_ROOT/lifecycle/release-policy.json"
DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_absent()   { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain: $3"; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
digest_of() { printf 'sha256:%s' "$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1)"; }
# snap <dir> ; sets SNAP — every entry's name, mode, size, mtime and link
# target (GNU stat -c, else BSD stat -f) plus every file's cksum. An empty
# snapshot of a non-empty directory is itself a failure, never a vacuous match.
SNAP=""
snap() {
  SNAP="$(cd "$1" 2>/dev/null && {
    { find . -exec stat -c '%n %a %s %Y %N' {} + 2>/dev/null || find . -exec stat -f '%N %Lp %z %m %Y' {} + 2>/dev/null; } | sort
    find . -type f -exec cksum {} + 2>/dev/null | sort; })"
  if [[ -z "$SNAP" && -n "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    bad "snapshot of $1 is empty although the directory is not"
    SNAP="SNAPSHOT_FAILED.$RANDOM.$RANDOM"
  fi
}

# --- stubs: a fixture prox-ops served from $REMOTE/<sha>/<path> ---------------
# git and curl run from an empty environment, so the stubs cannot see test
# variables: their paths are baked in, and they record what they were given.
STUBS="$TMPROOT/stubs"; REMOTE="$TMPROOT/remote"; LOG="$TMPROOT/stub.log"; OUT="$TMPROOT/out"
mkdir -p "$STUBS" "$REMOTE" "$OUT"; : >"$LOG"
TOOLS="$STUBS:/usr/bin:/bin" # the tool path seam: the stubs first, never the caller's PATH
cat >"$STUBS/git" <<SH
#!/usr/bin/env bash
while [[ "\$1" == -c ]]; do printf 'git-config %s\n' "\$2" >>"$LOG"; shift 2; done
[[ "\$1" == ls-remote ]] || exit 2
printf 'git %s HOME=%s canary=%s global=%s system=%s path=%s\n' "\$*" "\$HOME" "\${AFK_TEST_CANARY:-}" \
  "\${GIT_CONFIG_GLOBAL:-}" "\${GIT_CONFIG_SYSTEM:-}" "\$PATH" >>"$LOG"
[[ ! -e "$REMOTE/GIT_FAIL" ]] || exit 128
if [[ -e "$REMOTE/LSREMOTE" ]]; then cat "$REMOTE/LSREMOTE"; exit 0; fi
[[ -s "$REMOTE/HEAD" ]] || exit 128
printf '%s\trefs/heads/main\n' "\$(cat "$REMOTE/HEAD")"
SH
cat >"$STUBS/curl" <<SH
#!/usr/bin/env bash
out="" url=""
while (( \$# )); do case "\$1" in -o) out="\$2"; shift ;; https://*) url="\$1" ;; esac; shift; done
printf 'curl %s HOME=%s canary=%s\n' "\$url" "\$HOME" "\${AFK_TEST_CANARY:-}" >>"$LOG"
[[ ! -e "$REMOTE/CURL_FAIL" ]] || exit 28
rel="\${url#https://raw.githubusercontent.com/jlengelbrecht/prox-ops/}"
[[ "\$rel" != "\$url" && -f "$REMOTE/\$rel" ]] || exit 22
cp "$REMOTE/\$rel" "\$out"
SH
chmod +x "$STUBS"/*

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
SHA3=3333333333333333333333333333333333333333

# publish <sha> <version> <catalog text> [jq filter over the manifest] — makes
# <sha> the head of main with a manifest naming a catalog at that commit.
publish() {
  local d="$REMOTE/$1" cpath="clients/agent-router/catalog.yaml"
  mkdir -p "$d/clients/agent-router"
  printf '%s\n' "$3" >"$d/$cpath"
  jq -n --arg v "$2" --arg dg "$(digest_of "$d/$cpath")" --arg p "$cpath" \
    '{schema: "prox-ops/agent-router-client/v1",
      catalog: {document_version: $v, digest: $dg, path: $p},
      validator: {version: "v0.2.3"}}' | jq "${4:-.}" >"$d/clients/agent-router/manifest.json"
  printf '%s\n' "$1" >"$REMOTE/HEAD"
}

RC=0
XENV=()
cs() { # <home> <out-name> <function> [args...] ; sets RC — the library as the command runs it
  local h="$1" o="$2"; shift 2
  # shellcheck disable=SC2016
  env -i PATH="$STUBS:$PATH" HOME="$h" LANG=C AFK_TEST_CANARY=must-not-reach-a-fetch \
    AFK_CATALOG_SYNC_TOOL_PATH="$TOOLS" \
    AFK_STATE_DIR="$h/.local/state/agent-flow-kit" AFK_SKILLS_HOME="$h/.agents/skills" \
    AFK_INSTALL_ROOT="$KIT_ROOT" AFK_RELEASE_POLICY="$POLICY" AFK_AUTO_UPDATE_PLATFORM="${PLATFORM:-linux}" \
    ${XENV[@]+"${XENV[@]}"} \
    bash -c 'set -uo pipefail
      source "$AFK_INSTALL_ROOT/lib/afk-auto-update.sh"; source "$AFK_INSTALL_ROOT/lib/afk-catalog-sync.sh"
      "$@"' _ "$@" >"$OUT/$o.out" 2>"$OUT/$o.err"
  RC=$?
}
new_home() { local h="$TMPROOT/$1"; mkdir -p "$h/.agents/skills"; printf '%s\n' "$h"; }
CAT_REL=".config/agent-flow-kit/trusted-catalogs"

head1 "The source is declared once, in the kit policy"
assert_eq "manifest repository" "$(jq -r .catalog_source.repository_url "$POLICY")" "https://github.com/jlengelbrecht/prox-ops"
assert_eq "manifest path" "$(jq -r .catalog_source.manifest_path "$POLICY")" "clients/agent-router/manifest.json"
assert_eq "branch" "$(jq -r .catalog_source.branch "$POLICY")" "main"

head1 "Happy path: install, link, record (AC-1, AC-2)"
H="$(new_home happy)"; D="$H/$CAT_REL"
publish "$SHA1" "1.9.1" "document_version: 1.9.1"
DG1="$(digest_of "$REMOTE/$SHA1/clients/agent-router/catalog.yaml")"
: >"$LOG"
cs "$H" apply1 afk_cmd_catalog_sync apply false
assert_eq "apply succeeds" "$RC" "0"
assert_contains "reports INSTALLED" "$(cat "$OUT/apply1.out")" "catalog-sync: INSTALLED"
F1="trusted-catalog-1.9.1-${DG1:7:12}.yaml"
assert_eq "digest-named file installed" "$(cat "$D/$F1" 2>/dev/null)" "document_version: 1.9.1"
assert_eq "installed read-only (0444)" "$(mode_of "$D/$F1")" "444"
assert_eq "current.yaml links to it" "$(readlink "$D/current.yaml")" "$F1"
ST="$H/.local/state/agent-flow-kit/catalog/latest.json"
assert_eq "state records the outcome" "$(jq -r .outcome "$ST")" "INSTALLED"
assert_eq "state records the source sha" "$(jq -r .source_sha "$ST")" "$SHA1"
assert_eq "state records the digest" "$(jq -r .digest "$ST")" "$DG1"
assert_eq "state records the document version" "$(jq -r .document_version "$ST")" "1.9.1"
assert_contains "state records fetched_at" "$(jq -r .fetched_at "$ST")" "T"
assert_eq "resolves main by git ls-remote" "$(grep -c "^git ls-remote -- https://github.com/jlengelbrecht/prox-ops refs/heads/main " "$LOG")" "1"
assert_contains "no credential helper" "$(cat "$LOG")" "git-config credential.helper="
assert_eq "manifest fetched at the resolved sha" \
  "$(grep -c "^curl https://raw.githubusercontent.com/jlengelbrecht/prox-ops/$SHA1/clients/agent-router/manifest.json " "$LOG")" "1"
assert_eq "catalog fetched at the same sha" \
  "$(grep -c "^curl https://raw.githubusercontent.com/jlengelbrecht/prox-ops/$SHA1/clients/agent-router/catalog.yaml " "$LOG")" "1"
assert_eq "every fetch carries the resolved sha" "$(grep '^curl ' "$LOG" | grep -vc "/prox-ops/$SHA1/")" "0"
assert_absent "no caller environment reaches git or curl" "$(cat "$LOG")" "canary=must-not"
assert_eq "git and curl see no user HOME" "$(grep -E '^(git|curl) ' "$LOG" | grep -vc 'HOME=/nonexistent')" "0"
assert_contains "no user git config" "$(cat "$LOG")" "global=/dev/null"
assert_contains "no system git config" "$(cat "$LOG")" "system=/dev/null"
assert_contains "TLS verification forced on" "$(cat "$LOG")" "git-config http.sslVerify=true"
assert_contains "git sees only the fixed tool PATH" "$(cat "$LOG")" "path=$TOOLS"
assert_eq "nothing written inside ~/.agents/skills" "$(find "$H/.agents/skills" -mindepth 1 | wc -l | tr -d ' ')" "0"
assert_eq "no scratch left behind" "$(find "$H/.local/state/agent-flow-kit/catalog" -name '.fetch.*' | wc -l | tr -d ' ')" "0"

head1 "Re-run: ALREADY_CURRENT, no catalog writes"
snap "$D"; BEFORE="$SNAP"
assert_contains "the snapshot sees the installed file" "$BEFORE" "$F1"
cs "$H" apply2 afk_cmd_catalog_sync apply true
assert_eq "re-run succeeds" "$RC" "0"
assert_eq "re-run reports ALREADY_CURRENT" "$(jq -r .outcome "$OUT/apply2.out")" "ALREADY_CURRENT"
snap "$D"; assert_eq "the catalog directory is untouched" "$SNAP" "$BEFORE"
cs "$H" check1 afk_cmd_catalog_sync check false
assert_contains "--check reports ALREADY_CURRENT" "$(cat "$OUT/check1.out")" "ALREADY_CURRENT"

head1 "--check writes nothing"
publish "$SHA2" "1.9.2" "document_version: 1.9.2"
DG2="$(digest_of "$REMOTE/$SHA2/clients/agent-router/catalog.yaml")"
STATE_BEFORE="$(cat "$ST")"
cs "$H" check2 afk_cmd_catalog_sync check true
assert_eq "--check succeeds" "$RC" "0"
assert_eq "--check reports UPDATE_AVAILABLE" "$(jq -r .outcome "$OUT/check2.out")" "UPDATE_AVAILABLE"
assert_eq "--check reports the live digest" "$(jq -r .digest "$OUT/check2.out")" "$DG2"
snap "$D"; assert_eq "--check leaves the catalogs" "$SNAP" "$BEFORE"
assert_eq "--check leaves the state file" "$(cat "$ST")" "$STATE_BEFORE"

head1 "Fail closed, keep last good (AC-3)"
fail_case() { # <name> <expected reason> <expected rc>
  cs "$H" "$1" afk_cmd_catalog_sync apply false
  assert_eq "$1: exits $3" "$RC" "$3"
  assert_contains "$1: names $2" "$(cat "$OUT/$1.out" "$OUT/$1.err")" "$2"
  assert_eq "$1: current.yaml unchanged" "$(readlink "$D/current.yaml")" "$F1"
  assert_eq "$1: recorded as FAILED" "$(jq -r .outcome "$ST")" "FAILED"
  assert_eq "$1: reason recorded" "$(jq -r .reason "$ST")" "$2"
  assert_eq "$1: last verified kept" "$(jq -r .last_verified.digest "$ST")" "$DG1"
}
publish "$SHA2" "1.9.2" "document_version: 1.9.2" ".catalog.digest = \"$DG1\""
fail_case digest-mismatch DIGEST_MISMATCH 4
publish "$SHA2" "1.9.2" "x" '.schema = "prox-ops/agent-router-client/v2"'
fail_case bad-schema SCHEMA_UNSUPPORTED 4
publish "$SHA2" "1.9.2" "x" '.catalog.path = "../../etc/passwd"'
fail_case traversal PATH_REJECTED 4
publish "$SHA2" "1.9.2" "x" '.catalog.path = "/etc/passwd"'
fail_case absolute PATH_REJECTED 4
publish "$SHA2" "1.9.2" "x" '.catalog.path = "clients/a b.yaml"'
fail_case bad-chars PATH_REJECTED 4
publish "$SHA2" "1.9.2" "x" 'del(.catalog.digest)'
fail_case no-digest MANIFEST_INVALID 4
publish "$SHA2" "1.9.2" "x"
printf '{"schema": "prox-ops/agent-router-client/v1", "catalog": ' >"$REMOTE/$SHA2/clients/agent-router/manifest.json"
fail_case malformed MANIFEST_INVALID 4
publish "$SHA2" "1.9.2" "x"
: >"$REMOTE/GIT_FAIL"
fail_case git-unreachable SOURCE_UNREACHABLE 5
rm -f "$REMOTE/GIT_FAIL"; : >"$REMOTE/CURL_FAIL"
fail_case curl-unreachable SOURCE_UNREACHABLE 5
rm -f "$REMOTE/CURL_FAIL"
assert_eq "no failure left a stray file" "$(find "$D" -name '.*' -type f -o -name '.*' -type l | wc -l | tr -d ' ')" "0"

head1 "Unknown manifest fields are accepted; older pins stay"
publish "$SHA3" "1.9.2" "document_version: 1.9.2" '.future_field = {"x": 1} | .catalog.extra = true'
DG3="$(digest_of "$REMOTE/$SHA3/clients/agent-router/catalog.yaml")"
cs "$H" apply3 afk_cmd_catalog_sync apply false
assert_eq "extra fields: apply succeeds" "$RC" "0"
F3="trusted-catalog-1.9.2-${DG3:7:12}.yaml"
assert_eq "current.yaml re-pointed" "$(readlink "$D/current.yaml")" "$F3"
assert_eq "the older digest-named file is kept" "$(cat "$D/$F1")" "document_version: 1.9.1"
assert_eq "state records the new sha" "$(jq -r .last_verified.source_sha "$ST")" "$SHA3"

head1 "Only the exact refs/heads/main line counts (decoy refs, bad ids)"
SHA4=4444444444444444444444444444444444444444
publish "$SHA4" "6.6.6" "decoy: true"; printf '%s\n' "$SHA3" >"$REMOTE/HEAD"
HD="$(new_home decoy)"; DD="$HD/$CAT_REL"; STD="$HD/.local/state/agent-flow-kit/catalog/latest.json"
printf '%s\ta/refs/heads/main\n%s\trefs/heads/main\n' "$SHA4" "$SHA3" >"$REMOTE/LSREMOTE"
: >"$LOG"
cs "$HD" decoy-first afk_cmd_catalog_sync apply false
assert_eq "decoy listed first: apply succeeds" "$RC" "0"
assert_eq "decoy listed first: the real main is installed" "$(readlink "$DD/current.yaml")" "$F3"
assert_eq "decoy listed first: manifest fetched at the real main" \
  "$(grep -c "^curl https://raw.githubusercontent.com/jlengelbrecht/prox-ops/$SHA3/clients/agent-router/manifest.json " "$LOG")" "1"
assert_eq "decoy listed first: catalog fetched at the real main" \
  "$(grep -c "^curl https://raw.githubusercontent.com/jlengelbrecht/prox-ops/$SHA3/clients/agent-router/catalog.yaml " "$LOG")" "1"
assert_eq "decoy listed first: nothing fetched at the decoy sha" "$(grep -c "/prox-ops/$SHA4/" "$LOG")" "0"
assert_eq "decoy listed first: the decoy catalog is never installed" "$(find "$DD" -name 'trusted-catalog-6.6.6-*' | wc -l | tr -d ' ')" "0"
assert_eq "decoy listed first: state records the real sha" "$(jq -r .source_sha "$STD")" "$SHA3"
decoy_fail() { # <name> <ls-remote output>
  printf '%b' "$2" >"$REMOTE/LSREMOTE"; : >"$LOG"
  cs "$HD" "$1" afk_cmd_catalog_sync apply false
  assert_eq "$1: exits 5" "$RC" "5"
  assert_eq "$1: SOURCE_UNREACHABLE recorded" "$(jq -r .reason "$STD")" "SOURCE_UNREACHABLE"
  assert_eq "$1: nothing fetched" "$(grep -c '^curl ' "$LOG")" "0"
  assert_eq "$1: current.yaml unchanged" "$(readlink "$DD/current.yaml")" "$F3"
}
decoy_fail decoy-only "$SHA4\ta/refs/heads/main\n"
decoy_fail non-hex-sha "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\trefs/heads/main\n"
decoy_fail uppercase-sha "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\trefs/heads/main\n"
decoy_fail short-sha "${SHA3:0:39}\trefs/heads/main\n"
rm -f "$REMOTE/LSREMOTE"
mkdir -p "$TMPROOT/no-tools"; : >"$LOG"
XENV=(AFK_CATALOG_SYNC_TOOL_PATH="$TMPROOT/no-tools"); cs "$HD" no-tools afk_cmd_catalog_sync apply false; XENV=()
assert_eq "no git/curl in the fixed tool path: exits 5" "$RC" "5"
assert_eq "no git/curl in the fixed tool path: SOURCE_UNREACHABLE" "$(jq -r .reason "$STD")" "SOURCE_UNREACHABLE"
assert_eq "the caller's PATH never supplies git or curl" "$(grep -cE '^(git|curl) ' "$LOG")" "0"

head1 "current.yaml that is a directory, or a link to one, is refused (INSTALL_FAILED)"
dir_case() { # <name> ; $HX/$CAT_REL/current.yaml already set up
  cs "$HX" "$1" afk_cmd_catalog_sync apply false
  assert_eq "$1: exits 4" "$RC" "4"
  assert_contains "$1: reports INSTALL_FAILED" "$(cat "$OUT/$1.out")" "INSTALL_FAILED"
  assert_absent "$1: never reports INSTALLED" "$(cat "$OUT/$1.out")" "catalog-sync: INSTALLED"
  assert_eq "$1: INSTALL_FAILED recorded" "$(jq -r .reason "$HX/.local/state/agent-flow-kit/catalog/latest.json")" "INSTALL_FAILED"
  assert_eq "$1: no temp link left anywhere" "$(find "$HX/$CAT_REL" "$TMPROOT/elsewhere" -name '.current.tmp.*' | wc -l | tr -d ' ')" "0"
}
HX="$(new_home dirlink)"; mkdir -p "$HX/$CAT_REL" "$TMPROOT/elsewhere"
ln -s "$TMPROOT/elsewhere" "$HX/$CAT_REL/current.yaml"
dir_case link-to-dir
assert_eq "link-to-dir: the link still points at the directory" "$(readlink "$HX/$CAT_REL/current.yaml")" "$TMPROOT/elsewhere"
assert_eq "link-to-dir: nothing moved into the directory" "$(find "$TMPROOT/elsewhere" -mindepth 1 | wc -l | tr -d ' ')" "0"
rm -f "$HX/$CAT_REL/current.yaml"; mkdir "$HX/$CAT_REL/current.yaml"
dir_case plain-dir
assert_eq "plain-dir: the directory is left empty" "$(find "$HX/$CAT_REL/current.yaml" -mindepth 1 | wc -l | tr -d ' ')" "0"

head1 "A directory or symlink at the digest-named catalog path is refused before any write (INSTALL_FAILED)"
HG="$(new_home digestpath)"; DGDIR="$HG/$CAT_REL"; STG="$HG/.local/state/agent-flow-kit/catalog/latest.json"
cs "$HG" digestpath-seed afk_cmd_catalog_sync apply false
assert_eq "digestpath-seed: apply succeeds" "$RC" "0"
assert_eq "digestpath-seed: current.yaml links the seeded file" "$(readlink "$DGDIR/current.yaml")" "$F3"
SHA5=5555555555555555555555555555555555555555
publish "$SHA5" "1.9.3" "document_version: 1.9.3"
DG5="$(digest_of "$REMOTE/$SHA5/clients/agent-router/catalog.yaml")"
F5="trusted-catalog-1.9.3-${DG5:7:12}.yaml"
digest_path_case() { # <name>
  cs "$HG" "$1" afk_cmd_catalog_sync apply false
  assert_eq "$1: exits 4" "$RC" "4"
  assert_contains "$1: reports INSTALL_FAILED" "$(cat "$OUT/$1.out")" "INSTALL_FAILED"
  assert_absent "$1: never reports INSTALLED" "$(cat "$OUT/$1.out")" "catalog-sync: INSTALLED"
  assert_eq "$1: current.yaml unchanged" "$(readlink "$DGDIR/current.yaml")" "$F3"
  assert_eq "$1: last_verified digest kept" "$(jq -r .last_verified.digest "$STG")" "$DG3"
  assert_eq "$1: reason recorded" "$(jq -r .reason "$STG")" "INSTALL_FAILED"
  assert_eq "$1: no stray temp files" "$(find "$DGDIR" -name '.*' -type f -o -name '.*' -type l | wc -l | tr -d ' ')" "0"
}
mkdir "$DGDIR/$F5"
digest_path_case digest-path-is-dir
assert_eq "digest-path-is-dir: the directory is left empty" "$(find "$DGDIR/$F5" -mindepth 1 | wc -l | tr -d ' ')" "0"
rmdir "$DGDIR/$F5"
ln -s "$TMPROOT/elsewhere" "$DGDIR/$F5"
digest_path_case digest-path-is-symlink
assert_eq "digest-path-is-symlink: the symlink is untouched" "$(readlink "$DGDIR/$F5")" "$TMPROOT/elsewhere"
rm -f "$DGDIR/$F5"
printf '%s\n' "$SHA3" >"$REMOTE/HEAD" # restore the fixture head the later sections expect

head1 "The command: agent-flow-kit catalog-sync [--check|--apply] [--json] (AC-1)"
afk_cli() { # <home> <out-name> [args...] ; sets RC — the installed entry point
  local h="$1" o="$2"; shift 2
  env -i PATH="$STUBS:$PATH" HOME="$h" LANG=C \
    AFK_STATE_DIR="$h/.local/state/agent-flow-kit" AFK_PM_DIR="$h/.local/state/agent-flow-kit/pm" \
    AFK_RELEASE_POLICY="$POLICY" AFK_CATALOG_SYNC_TOOL_PATH="$TOOLS" \
    bash "$KIT_ROOT/bin/agent-flow-kit" catalog-sync "$@" >"$OUT/$o.out" 2>"$OUT/$o.err"
  RC=$?
}
HC="$(new_home cli)"
afk_cli "$HC" cli-apply --apply --json
assert_eq "cli: --apply exits 0" "$RC" "0"
assert_eq "cli: --apply --json reports INSTALLED" "$(jq -r .outcome "$OUT/cli-apply.out" 2>/dev/null)" "INSTALLED"
assert_eq "cli: current.yaml links the verified file" "$(readlink "$HC/$CAT_REL/current.yaml")" "$F3"
afk_cli "$HC" cli-check
assert_eq "cli: the default is --check" "$RC" "0"
assert_contains "cli: --check reports ALREADY_CURRENT" "$(cat "$OUT/cli-check.out")" "catalog-sync: ALREADY_CURRENT"
afk_cli "$HC" cli-both --check --apply
assert_eq "cli: --check with --apply is a usage failure" "$RC" "1"
afk_cli "$HC" cli-remove --remove
assert_eq "cli: an option catalog-sync does not take is a usage failure" "$RC" "1"

head1 "Resolution order: env, then launcher.catalog_path, then current.yaml (AC-4)"
PIN="$TMPROOT/pinned-catalog.yaml"; printf 'document_version: 1.8.0\n' >"$PIN"
ENVCAT="$TMPROOT/env-catalog.yaml"; printf 'document_version: 0.0.1\n' >"$ENVCAT"
printf 'launcher:\n  catalog_path: "%s"\n' "$PIN" >"$TMPROOT/subs-pinned.yaml"
printf 'launcher:\n  catalog_path: ""\n' >"$TMPROOT/subs-empty.yaml"
resolve() { # <home> <config> [env catalog] — dispatch.sh's own function
  # shellcheck disable=SC2016
  env -i PATH="$PATH" HOME="$1" AGENT_STAMP_VALIDATE_CATALOG_PATH="${3:-}" \
    bash -c 'source "$1"; CONFIG_FILE="$2"; resolve_catalog_path' _ "$DISPATCH" "$2" 2>/dev/null
}
if command -v yq >/dev/null 2>&1; then
  assert_eq "dispatch: env beats config" "$(resolve "$H" "$TMPROOT/subs-pinned.yaml" "$ENVCAT")" "$ENVCAT"
  assert_eq "dispatch: config beats current.yaml" "$(resolve "$H" "$TMPROOT/subs-pinned.yaml")" "$PIN"
else
  bad "yq is required to exercise dispatch.sh's config rule"
fi
assert_eq "dispatch: empty config falls to current.yaml" "$(resolve "$H" "$TMPROOT/subs-empty.yaml")" "$H/$CAT_REL/current.yaml"
assert_eq "dispatch: nothing resolves to empty" "$(resolve "$(new_home bare)" "$TMPROOT/subs-empty.yaml")" ""
assert_contains "make-stamp.sh falls back to current.yaml after the config" \
  "$(grep -A3 "yq_cfg '.launcher.catalog_path'" "$KIT_ROOT/files/model-router/scripts/make-stamp.sh")" \
  "trusted-catalogs/current.yaml"

S=""
status_of() { # <home> [VAR=value...] ; sets S — the catalog section as status computes it
  local h="$1"; shift
  XENV=("$@"); cs "$h" status afk_catalog_status_json; XENV=()
  S="$(cat "$OUT/status.out")"
}
status_of "$H" AGENT_STAMP_VALIDATE_CATALOG_PATH="$ENVCAT" AGENT_FLOW_CONFIG="$TMPROOT/subs-pinned.yaml"
assert_eq "status: env rule" "$(jq -r .resolved_by <<<"$S")" "env"
assert_eq "status: env rule digest" "$(jq -r .digest <<<"$S")" "$(digest_of "$ENVCAT")"
assert_absent "status: the env value is never echoed" "$S" "$ENVCAT"
status_of "$H" AGENT_FLOW_CONFIG="$TMPROOT/subs-pinned.yaml"
assert_eq "status: config rule" "$(jq -r .resolved_by <<<"$S")" "config"
assert_eq "status: config digest" "$(jq -r .digest <<<"$S")" "$(digest_of "$PIN")"
assert_contains "status: CATALOG_PIN_SHADOWED when the pin differs" "$(jq -c .findings <<<"$S")" '{"code":"CATALOG_PIN_SHADOWED","severity":"warning"}'
printf 'launcher:\n  catalog_path: %s\n' "$H/$CAT_REL/current.yaml" >"$TMPROOT/subs-current.yaml"
status_of "$H" AGENT_FLOW_CONFIG="$TMPROOT/subs-current.yaml"
assert_absent "status: no shadow when the pin is current.yaml" "$(jq -c .findings <<<"$S")" "CATALOG_PIN_SHADOWED"
status_of "$H" AGENT_FLOW_CONFIG="$TMPROOT/subs-empty.yaml"
assert_eq "status: synced rule" "$(jq -r .resolved_by <<<"$S")" "synced"
assert_eq "status: synced digest" "$(jq -r .digest <<<"$S")" "$DG3"
assert_eq "status: last sync outcome" "$(jq -r .last_sync.outcome <<<"$S")" "INSTALLED"
assert_eq "status: a fresh verified sync has no findings" "$(jq -c .findings <<<"$S")" "[]"

head1 "Status findings: failed, stale, unresolved (AC-6)"
: >"$REMOTE/GIT_FAIL"; cs "$H" fail-again afk_cmd_catalog_sync apply false; rm -f "$REMOTE/GIT_FAIL"
status_of "$H" AGENT_FLOW_CONFIG="$TMPROOT/subs-empty.yaml"
assert_contains "CATALOG_SYNC_FAILED after a failed sync" "$(jq -c .findings <<<"$S")" "CATALOG_SYNC_FAILED"
assert_absent "a recent verified sync is not stale" "$(jq -c .findings <<<"$S")" "CATALOG_SYNC_STALE"
jq '.last_verified.at = "2000-01-01T00:00:00Z"' "$ST" >"$ST.tmp" && mv "$ST.tmp" "$ST"
status_of "$H" AGENT_FLOW_CONFIG="$TMPROOT/subs-empty.yaml"
assert_contains "CATALOG_SYNC_STALE past 3x the interval" "$(jq -c .findings <<<"$S")" "CATALOG_SYNC_STALE"
status_of "$(new_home never-synced)" AGENT_FLOW_CONFIG="$TMPROOT/subs-pinned.yaml"
assert_eq "never synced: no last sync" "$(jq -r .last_sync <<<"$S")" "null"
assert_contains "never synced: CATALOG_SYNC_STALE" "$(jq -c .findings <<<"$S")" '{"code":"CATALOG_SYNC_STALE","severity":"warning"}'
status_of "$(new_home unresolved)" AGENT_FLOW_CONFIG="$TMPROOT/subs-empty.yaml"
assert_eq "nothing resolves: resolved_by null" "$(jq -r .resolved_by <<<"$S")" "null"
assert_contains "CATALOG_UNRESOLVED is an error" "$(jq -c .findings <<<"$S")" '{"code":"CATALOG_UNRESOLVED","severity":"error"}'

head1 "Scheduling never changes the release result (AC-5)"
mkdir -p "$H/.local/state/agent-flow-kit/releases"
printf '%s\n' '{"state":"CONVERGED","reason":"RELEASE_APPLIED","ended_at":"2026-09-26T00:00:00Z"}' \
  >"$H/.local/state/agent-flow-kit/releases/latest.json"
REL_BEFORE="$(cksum <"$H/.local/state/agent-flow-kit/releases/latest.json")"
publish "$SHA2" "1.9.2" "x" ".catalog.digest = \"$DG1\""
cs "$H" scheduled afk_catalog_scheduled
assert_eq "a failing scheduled sync returns 0" "$RC" "0"
assert_contains "the failure is logged" "$(cat "$OUT/scheduled.out")" "the release result is unaffected"
assert_eq "the release result is byte-identical" "$(cksum <"$H/.local/state/agent-flow-kit/releases/latest.json")" "$REL_BEFORE"
assert_eq "the failure is recorded in the catalog state" "$(jq -r .reason "$ST")" "DIGEST_MISMATCH"
cs "$H" unit eval 'afk_au_paths; afk_au_systemd_service'
UNIT="$(cat "$OUT/unit.out")"
assert_contains "the Linux unit runs catalog-sync after the release, failure ignored" "$UNIT" \
  "ExecStopPost=-\"$H/.agents/skills/afk-runtime/bin/agent-flow-kit\" catalog-sync --apply"
assert_eq "the release step is still the main process" "$(grep -c '^ExecStart=' <<<"$UNIT")" "1"
HM="$(new_home mac)"
publish "$SHA1" "1.9.1" "document_version: 1.9.1"
PLATFORM=darwin cs "$HM" mac-check afk_cmd_enroll_auto_update check "" ""
assert_eq "macOS: the check also syncs the catalog" \
  "$(jq -r .outcome "$HM/.local/state/agent-flow-kit/catalog/latest.json" 2>/dev/null)" "INSTALLED"
assert_contains "macOS: the catalog line reaches the check log" "$(cat "$OUT/mac-check.out")" "catalog-sync: INSTALLED"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
