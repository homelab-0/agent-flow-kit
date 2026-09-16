#!/usr/bin/env bash
# Hermes remains a human presentation surface: this emits a card and exposes
# no routing or worker-creation verb.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$HERE/orca-title.sh" --background --harness hermes >/dev/null 2>&1 || true
TEXT="$("$HERE/render-status.sh" --harness hermes "$@")"
jq -nc --arg text "$TEXT" '{schema:"afk-hermes-status-card/1",kind:"status_card",read_only:true,text:$text}'
