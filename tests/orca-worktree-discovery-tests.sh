#!/usr/bin/env bash
# Exercise dispatch discovery without a live Orca or a harness launch.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="${1:-$ROOT/files/model-router/scripts/dispatch.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
pass=0 fail=0
here="$TMP/worktree with spaces"
mkdir -p "$here"

# The requested workspace is beyond the first page of the global list.
jq -n '{ok:true,result:{totalCount:218,truncated:true,worktrees:
  [range(200) | {id:("other::/work/"+tostring),path:("/work/"+tostring)}]}}' >"$TMP/list.json"
jq -n --arg p "$here" '{ok:true,result:{worktree:{id:("repo::"+$p),path:$p}}}' >"$TMP/current.json"

# Run the selector in a subshell with a stubbed Orca command and fixture response.
probe() (
  # shellcheck source=/dev/null
  source "$DISPATCH"
  # Called indirectly by the sourced dispatcher's selector.
  # shellcheck disable=SC2317,SC2329
  orca_json() {
    printf '%s\n' "$*" >>"$TMP/calls"
    case "$*" in
      "worktree show --worktree path:$here")
        [[ $# == 4 && $4 == "path:$here" ]] || return 1
        printf '%s' "${cli_stderr:-}" >&2
        cat "$TMP/current.json"; return "${current_rc:-0}" ;;
      'worktree list') cat "$TMP/list.json" ;;
      *) return 1 ;;
    esac
  }
  orca_worktree_selector "$here"
)

# Check the selector output, refusal status and safe diagnostic for one fixture.
# Arguments: case name, expected selector (empty for refusal), optional safe reason.
check() {
  local name="$1" expected="$2" reason="${3:-lookup_failed}" out rc=0 diagnostic=""
  if [[ -z "$expected" ]]; then
    diagnostic="dispatch: Unable to verify Orca worktree (exit ${current_rc:-0}, reason $reason). Check Orca and retry."
  fi
  : >"$TMP/calls"
  out="$(probe 2>"$TMP/stderr")" || rc=$?
  if [[ "$out" == "$expected" && "$(cat "$TMP/stderr")" == "$diagnostic" ]] &&
     { [[ -n "$expected" && "$rc" == 0 ]] || [[ -z "$expected" && "$rc" != 0 ]]; }; then
    pass=$((pass+1))
  else
    printf 'FAIL %s (exit=%s)\n' "$name" "$rc"; fail=$((fail+1))
  fi
}

check 'managed workspace outside the first 200 entries' "repo::$here"
if [[ "$(cat "$TMP/calls")" == "worktree show --worktree path:$here" ]]; then
  pass=$((pass+1))
else
  printf 'FAIL discovery depends on a global workspace list\n'; fail=$((fail+1))
fi

# A response naming another workspace must not authorize launch.
jq -n '{ok:true,result:{worktree:{id:"repo::/elsewhere",path:"/elsewhere"}}}' >"$TMP/current.json"
check 'resolved workspace path differs from canonical cwd' ''
jq -n --arg p "$here" '{ok:true,result:{worktree:{id:"repo::opaque-workspace",path:$p}}}' >"$TMP/current.json"
check 'opaque workspace selector is supported' 'repo::opaque-workspace'
jq -n --arg p "$here" '{ok:true,result:{worktree:{id:"",path:$p}}}' >"$TMP/current.json"
check 'empty selector' ''
jq -n --arg p "$here" '{ok:true,result:{worktree:{id:null,path:$p}}}' >"$TMP/current.json"
check 'missing selector' ''
printf '%s\n' '{"ok":true,"result":{"worktree":null}}' >"$TMP/current.json"
check 'unmanaged directory' ''
printf '%s\n' '{"ok":false,"error":{"code":"ambiguous_workspace"}}' >"$TMP/current.json"
check 'ambiguous workspace' '' ambiguous_workspace
printf '%s\n' 'not-json' >"$TMP/current.json"
check 'malformed CLI output' ''
jq -n --arg p "$here" '{ok:false,result:{worktree:{id:("repo::"+$p),path:$p}}}' >"$TMP/current.json"
check 'error envelope containing a plausible workspace' ''
jq -n --arg p "$here" '{ok:true,error:{code:"lookup_error"},result:{worktree:{id:("repo::"+$p),path:$p}}}' >"$TMP/current.json"
check 'contradictory success and error envelope' ''
jq -n --arg p "$here" '{ok:true,result:{worktree:{id:("repo::"+$p),path:$p}}}' >"$TMP/current.json"
current_rc=7
check 'failed CLI command containing a plausible workspace' ''
current_rc=0
cp "$TMP/current.json" "$TMP/extra.json"
cat "$TMP/extra.json" >>"$TMP/current.json"
check 'multiple response documents' ''

printf '%s\n' '{"ok":false,"error":{"code":"selector_not_found"}}' >"$TMP/current.json"
current_rc=9
check 'known error preserves command exit' '' selector_not_found
current_rc=0
printf '%s\n' '{"ok":false,"error":{"code":"private-fixture-value","message":"private-response-body"}}' >"$TMP/current.json"
check 'arbitrary error code and message stay private' ''
printf '%s\n' '{"ok":false,"error":{"code":{"nested":"private-fixture-value"}}}' >"$TMP/current.json"
check 'non-string error code stays private' ''
cli_stderr='private-cli-stderr'
current_rc=3
check 'raw CLI stderr stays private' ''

printf 'worktree discovery: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
