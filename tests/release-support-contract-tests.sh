#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
passed=0
failed=0

ok() { passed=$((passed + 1)); }
no() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

if jq -e '
  .schema=="afk-release-policy/2" and
  .trust.remote_url=="ssh://git@github.com/jlengelbrecht/agent-flow-kit.git" and
  .trust.ref=="refs/heads/master" and
  .rollout.authoritative_promotion==false and
  .automatic_rollback_bypass==false
' "$ROOT/lifecycle/release-policy.json" >/dev/null; then
  ok
else
  no "release policy retains the immutable trust and no-bypass contract"
fi

mkdir -p "$TMP/state/releases"
revision=0123456789abcdef0123456789abcdef01234567
jq -nc --arg revision "$revision" '{applied_revision:$revision}' >"$TMP/state/state.json"
jq -nc --arg revision "$revision" '{revision:$revision}' >"$TMP/state/releases/current.json"
freshness="$("$ROOT/bin/afk-session-freshness" --state-dir "$TMP/state")"
if jq -e '
  .schema=="afk-session-freshness/2" and .state=="ACCEPTED_LOCALLY" and
  .offline==true and .launch_authoritative==false and .last_good_verified==false
' <<<"$freshness" >/dev/null; then
  ok
else
  no "freshness is an offline observation, never launch authority"
fi

# A no-change acceptance records the installed revision next to the accepted
# target; freshness matches the install and still reports the target.
target=89abcdef0123456789abcdef0123456789abcdef
freshness_case() { # <current.json> <expected state:reason:accepted> <label>
  printf '%s\n' "$1" >"$TMP/state/releases/current.json"
  if [[ "$("$ROOT/bin/afk-session-freshness" --state-dir "$TMP/state" |
        jq -r '.state+":"+.reason+":"+.accepted_revision+":"+.applied_revision')" == "$2:$revision" ]]; then
    ok
  else
    no "$3"
  fi
}
freshness_case "{\"revision\":\"$target\",\"installed_revision\":\"$revision\"}" \
  "ACCEPTED_LOCALLY:RECORDED_LAST_GOOD:$target" "a no-change acceptance matches the installed revision"
freshness_case "{\"revision\":\"$target\",\"installed_revision\":\"$target\"}" \
  "MISMATCH:APPLIED_REVISION_DIFFERS_FROM_ACCEPTED_RELEASE:$target" "a recorded install that differs is a mismatch"
freshness_case "{\"revision\":\"$target\"}" \
  "MISMATCH:APPLIED_REVISION_DIFFERS_FROM_ACCEPTED_RELEASE:$target" "an older record without installed_revision is unchanged"

memory="$(AFK_STATE_DIR="$TMP/memory-state" "$ROOT/adapters/hindsight.sh" blind "$ROOT")"
if jq -e '
  .schema=="afk-memory-context/2" and .state=="DISABLED" and
  .native_integration=="BYPASSED_BY_SUPPORTED_CONFIG" and
  .environment.HINDSIGHT_DISABLED=="true" and .recall==[] and .retain==[]
' <<<"$memory" >/dev/null; then
  ok
else
  no "blind review disables native Hindsight recall and retain"
fi

if ! grep -RIlE '(api[_-]?key|token|password)[[:space:]]*[:=][[:space:]]*[^$<{[:space:]]' \
  "$ROOT/lifecycle/release-policy.json" "$ROOT/bin/afk-session-freshness" "$ROOT/adapters/hindsight.sh" >/dev/null; then
  ok
else
  no "release support carries no literal credential"
fi

printf '%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
