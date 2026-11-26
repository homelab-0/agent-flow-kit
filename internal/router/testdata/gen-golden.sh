#!/usr/bin/env bash
# Regenerates golden.json: the bash router's decision for every scenario in
# scenarios.json, with the pool probe and discovered models taken from the
# fixtures instead of the machine. The Go router must make the same picks.
#
#   bash internal/router/testdata/gen-golden.sh
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd -- "$here/../../.." && pwd -P)"
export HOME="$(mktemp -d)"; trap 'rm -rf -- "$HOME"' EXIT
export AFK_ROUTER_BENCHMARKS_FILE="$here/../benchmarks.json"
export AFK_ROUTER_SIGNALS_FILE="$HOME/none.json"
unset AFK_LITELLM_BASE_URL AFK_ROUTER_ALLOW_METERED_API AFK_ROUTER_PREFER_FREE AFK_ROUTER_ALLOW_FREE_REVIEWERS AFK_SECURITY_MODELS AFK_ROUTER_ONLY_HARNESSES
# AFK doesn't police which CLI uses which login, so the bash router's
# plan-login rules are taken out of a copy of it before it runs: a plan
# only in its own CLI, and OpenCode only with its own free models. Every
# other rule is compared as it is.
lib="$HOME/lib"; cp -R "$root/lib" "$lib"
sed -i.orig \
  -e '/select(\$cclass != "subscription" or (((\$own_plans/d' \
  -e '/select(\$c.harness != "opencode" or/d' \
  "$lib/afk-smart-router.sh"
if grep -q 'own_plans\[' "$lib/afk-smart-router.sh" || grep -q 'select(\$c.harness != "opencode"' "$lib/afk-smart-router.sh"; then
  echo "gen-golden: a plan-login rule is still in the bash router copy; update the sed patterns" >&2; exit 1
fi
# shellcheck source=/dev/null
. "$lib/afk-smart-router.sh"
afk_router_ensure_fresh_benchmarks() { :; }
PROBE=""
afk_router_probe_pools() { printf '%s' "$PROBE"; }

out="{}"
n="$(jq length "$here/scenarios.json")"
for ((i = 0; i < n; i++)); do
  s="$(jq -c ".[$i]" "$here/scenarios.json")"
  name="$(jq -r .name <<<"$s")"
  PROBE="$(jq -c --arg p "$(jq -r .probe <<<"$s")" '.[$p]' "$here/probes.json")"
  disc="$here/discovered.json"
  [[ "$(jq -r '.no_discovered // false' <<<"$s")" == true ]] && disc="$HOME/empty-disc.json" && printf '{"models":[]}' > "$disc"
  r="$(
    AFK_DISCOVERED_MODELS_FILE="$disc" \
    AFK_ROUTER_ONLY_HARNESSES="$(jq -r '(.only // []) | join(",")' <<<"$s")" \
    AFK_ROUTER_PREFER_FREE="$(jq -r 'if .prefer_free then "1" else "" end' <<<"$s")" \
    AFK_ROUTER_ALLOW_METERED_API="$(jq -r 'if .allow_metered then "true" else "" end' <<<"$s")" \
    AFK_ROUTER_ALLOW_FREE_REVIEWERS="$(jq -r 'if .allow_free_reviewers then "true" else "" end' <<<"$s")" \
    AFK_SECURITY_MODELS="$(jq -r '(.sec_models // []) | join(",")' <<<"$s")" \
    AFK_LITELLM_BASE_URL="$(jq -r '.gateway_url // ""' <<<"$s")" \
    afk_router_select_candidate "" "$(jq -r .stage <<<"$s")" "$(jq -r .risk <<<"$s")" \
      "$(jq -r '.builder_family // ""' <<<"$s")" "" \
      "$(jq -r '.round // 1' <<<"$s")" "$(jq -r '(.surfaces // ["code"]) | join(",")' <<<"$s")" \
      "$(jq -r '.diff // 0' <<<"$s")"
  )"
  out="$(jq -c --arg k "$name" --argjson r "$r" '. + {($k): $r}' <<<"$out")"
done
# AFK has no roles or memory modes; the bash router still reports them.
jq -S 'map_values(del(.role, .memory_mode))' <<<"$out" > "$here/golden.json"
echo "wrote $n decisions to golden.json"
