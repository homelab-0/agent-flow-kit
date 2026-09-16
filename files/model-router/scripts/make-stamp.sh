#!/usr/bin/env bash
# make-stamp.sh — turn an accepted POST /v1/route decision into the immutable
# ExecutionStamp that dispatch.sh later validates and launches from.
#
# This is the PM-side half of the seam. /v1/route recommends; a human accepts
# (or deliberately overrides); this script records that acceptance as a closed,
# frozen document. It is the LAST point at which the route can change: after the
# stamp is written, a different route requires a NEW /v1/route call and a NEW
# stamp, never an edit to this one.
#
# Usage:
#   make-stamp.sh --request  <route-request.json> --out <story.md.stamp.json> [opts]
#   make-stamp.sh --response <route-response.json> --story-id <id> --out <f> [opts]
#
#   --request <f>    a RouteRequest document; POSTed to $ROUTER/v1/route, and the
#                    task identity (story_id/title/tags/context_size) is taken
#                    from it, so the stamp cannot describe a different task than
#                    the one that was routed.
#   --response <f>   an already-obtained ExecutionProfile ('-' reads stdin).
#                    Requires --story-id; --title/--tag/--context-size optional.
#   --out <f>        where to write the stamp (dispatch.sh defaults to
#                    <story.md>.stamp.json).
#   --override-harness <h> --override-profile <p> --override-actor <who>
#   --override-reason <why>
#                    record a deliberate PRE-STAMP override. The FINAL fields
#                    are what gets validated; the override record is AUDIT
#                    PROVENANCE ONLY and grants no bypass of any rule.
#   --check          after writing, run agent-stamp-validate as an ADVISORY
#                    early warning. It is not the final validation: dispatch.sh
#                    re-validates immediately before every launch.
#
# Exit: 0 wrote a well-formed stamp; 1 refused (bad input/response/override);
#       2 usage or dependency error.

set -euo pipefail

log() { printf 'make-stamp: %s\n' "$*" >&2; }
die() { log "$1"; exit "${2:-1}"; }
# BSD+GNU portable (the kit runs on Linux and macOS).
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

REQUEST="" RESPONSE="" OUT="" STORY_ID="" TITLE="" CONTEXT_SIZE=""
OV_HARNESS="" OV_PROFILE="" OV_ACTOR="" OV_REASON="" CHECK=0
TAGS=()

while (( $# )); do
  case "$1" in
    --request)          REQUEST="$2"; shift 2 ;;
    --response)         RESPONSE="$2"; shift 2 ;;
    --out)              OUT="$2"; shift 2 ;;
    --story-id)         STORY_ID="$2"; shift 2 ;;
    --title)            TITLE="$2"; shift 2 ;;
    --tag)              TAGS+=("$2"); shift 2 ;;
    --context-size)     CONTEXT_SIZE="$2"; shift 2 ;;
    --override-harness) OV_HARNESS="$2"; shift 2 ;;
    --override-profile) OV_PROFILE="$2"; shift 2 ;;
    --override-actor)   OV_ACTOR="$2"; shift 2 ;;
    --override-reason)  OV_REASON="$2"; shift 2 ;;
    --check)            CHECK=1; shift ;;
    -h|--help)          sed -n '2,40p' "$0"; exit 0 ;;
    *)                  die "unknown argument: $1" 2 ;;
  esac
done

for dep in jq curl; do command -v "$dep" >/dev/null || die "missing dependency: $dep" 2; done
[[ -n "$OUT" ]] || die "--out is required" 2

ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${AGENT_FLOW_CONFIG:-${SUBSCRIPTIONS_FILE:-$ROUTER_DIR/subscriptions.yaml}}"
INVENTORY_BIN="${AGENT_FLOW_HARNESS_INVENTORY:-$ROUTER_DIR/scripts/harness-inventory.sh}"
AVAILABLE_BINDINGS_CONTRACT="${AFK_ROUTE_AVAILABLE_BINDINGS_CONTRACT:-0}"
yq_cfg() { [[ -f "$CONFIG_FILE" ]] && command -v yq >/dev/null && yq -r "$1 // \"\"" "$CONFIG_FILE" 2>/dev/null || true; }

ROUTER_URL="${AGENT_ROUTER_URL:-$(yq_cfg '.launcher.router_endpoint')}"
ROUTER_URL="${ROUTER_URL%/}"
TOKEN_ENV="${AGENT_ROUTER_TOKEN_ENV:-$(yq_cfg '.launcher.caller_token_env')}"
TOKEN_ENV="${TOKEN_ENV:-AGENT_ROUTER_TOKEN}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PROFILE="$TMP/profile.json"
INVENTORY="$TMP/available-bindings.json"
ROUTE_REQUEST="$TMP/route-request.json"

# ---- obtain the ExecutionProfile ------------------------------------------

if [[ -n "$REQUEST" ]]; then
  [[ -f "$REQUEST" ]] || die "no such route request: $REQUEST" 2
  jq -e . "$REQUEST" >/dev/null || die "route request is not valid JSON"
  jq -e 'has("available_bindings") | not' "$REQUEST" >/dev/null \
    || die "route request already contains available_bindings — this extension is launcher-owned and capability-gated" 2
  [[ -n "$ROUTER_URL" ]] || die "no router endpoint (AGENT_ROUTER_URL or launcher.router_endpoint)" 2
  token="${!TOKEN_ENV:-}"
  [[ -n "$token" ]] || die "\$$TOKEN_ENV is empty — the caller token is never stored in config" 2

  case "$AVAILABLE_BINDINGS_CONTRACT" in
    0|false|off|'')
      # The deployed POST /v1/route contract is the public compatibility
      # boundary. Preserve the caller's document exactly unless the server
      # capability has been explicitly negotiated out of band.
      cp -- "$REQUEST" "$ROUTE_REQUEST"
      ;;
    1|true|on)
      [[ -x "$INVENTORY_BIN" ]] || die "harness inventory is not executable" 2
      "$INVENTORY_BIN" --route >"$INVENTORY" \
        || die "harness inventory could not establish a current availability snapshot"
      jq -se '
        length == 1 and (.[0] |
          keys == ["bindings","expires_at","observed_at","schema"]
          and .schema == "afk-harness-inventory/1"
          and (.observed_at|type)=="string" and (.expires_at|type)=="string"
          and (.bindings|type)=="array"
          and all(.bindings[]; keys == ["entitlement_pool","harness","model_profile"]
            and (.harness|type)=="string" and (.harness|length)>0
            and (.model_profile|type)=="string" and (.model_profile|length)>0
            and ((.entitlement_pool==null) or ((.entitlement_pool|type)=="string" and (.entitlement_pool|length)>0))))
      ' "$INVENTORY" >/dev/null || die "harness inventory returned a malformed availability snapshot"
      jq --slurpfile available "$INVENTORY" '. + {available_bindings:$available[0]}' "$REQUEST" >"$ROUTE_REQUEST"
      log "attached negotiated harness inventory ($(jq '.bindings | length' "$INVENTORY") exact binding(s))"
      ;;
    *) die "AFK_ROUTE_AVAILABLE_BINDINGS_CONTRACT must be 0/off or 1/on" 2 ;;
  esac

  http="$(curl -sS -o "$PROFILE" -w '%{http_code}' -X POST "$ROUTER_URL/v1/route" \
          -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
          --max-time 30 -d @"$ROUTE_REQUEST" || true)"
  if [[ "$http" != "200" ]]; then
    log "POST /v1/route returned HTTP ${http:-000}:"
    jq -r '"  \(.code // "?"): \(.message // .detail // "no detail")"' "$PROFILE" >&2 2>/dev/null \
      || sed 's/^/  /' "$PROFILE" >&2
    die "no route decision — nothing to stamp"
  fi

  # Task identity comes from the request that produced this decision, so the
  # stamp can never claim different tags than the ones forbidden_for was
  # evaluated against.
  #
  # Every extraction below is `// ""`-guarded ON PURPOSE. Bare `jq -r .field`
  # prints the four-character string "null" for a missing OR explicitly-null
  # field, and that string then passes every downstream non-empty check as a
  # perfectly ordinary value. It LAUNDERS absent data into a valid-looking
  # identity before any validation can see it, which is the opposite of failing
  # closed. `// ""` collapses both null cases to empty, and empty is checked.
  STORY_ID="$(jq -r '.story_id // ""' "$REQUEST")"
  TITLE="$(jq -r '.title // ""' "$REQUEST")"
  CONTEXT_SIZE="$(jq -r '.context_size // ""' "$REQUEST")"
  # A null ELEMENT inside tags is the same hazard one level down: it would
  # stamp the literal tag "null" and be checked against forbidden_for as one.
  mapfile -t TAGS < <(jq -r '.tags[]? | select(. != null)' "$REQUEST")

  [[ -n "$STORY_ID" ]] \
    || die "route request has no story_id — refusing to stamp an attempt with no task identity. task.story_id is re-checked at validation, so a stamp without one is a stamp for nothing."
elif [[ -n "$RESPONSE" ]]; then
  if [[ "$RESPONSE" == "-" ]]; then cat > "$PROFILE"; else cp "$RESPONSE" "$PROFILE"; fi
  jq -e . "$PROFILE" >/dev/null || die "route response is not valid JSON"
  [[ -n "$STORY_ID" ]] || die "--story-id is required with --response" 2
else
  die "one of --request or --response is required" 2
fi

# ---- accept, or deliberately override, then freeze ------------------------

# `has(f)` alone is NOT a presence check: it is true for an explicitly-null
# field, which is what let a null harness reach `jq -r` and become the string
# "null" below. Require the key to exist AND carry a value. entitlement_pool is
# deliberately absent from this list — null is a LEGITIMATE value there (local
# execution draws on no pool), so it is checked for presence only.
for f in harness model_profile effort cost_class placement_policy placement_required \
         metered catalog_version expires_at; do
  jq -e "has(\"$f\") and (.[\"$f\"] != null)" "$PROFILE" >/dev/null 2>&1 \
    || die "route response is missing required field '$f', or has it set to null — not an ExecutionProfile"
done
jq -e 'has("entitlement_pool")' "$PROFILE" >/dev/null 2>&1 \
  || die "route response is missing required field 'entitlement_pool' — not an ExecutionProfile"

# `// ""`-guarded for the same reason as the request fields above.
FINAL_HARNESS="$(jq -r '.harness // ""' "$PROFILE")"
FINAL_PROFILE="$(jq -r '.model_profile // ""' "$PROFILE")"
[[ -n "$FINAL_HARNESS" && -n "$FINAL_PROFILE" ]] \
  || die "route response carries no usable harness/model_profile — refusing to stamp"
OVERRIDE='null'

if [[ -n "$OV_HARNESS$OV_PROFILE" ]]; then
  [[ -n "$OV_ACTOR" && -n "$OV_REASON" ]] \
    || die "an override needs --override-actor and --override-reason: an unexplained override is exactly the audit gap the record exists to close"
  OVERRIDE="$(jq -nc --arg a "$OV_ACTOR" \
                     --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                     --arg oh "$FINAL_HARNESS" --arg op "$FINAL_PROFILE" \
                     --arg r "$OV_REASON" \
                '{actor:$a, at:$at, original:{harness:$oh, model_profile:$op}, reason:$r}')"
  [[ -n "$OV_HARNESS" ]] && FINAL_HARNESS="$OV_HARNESS"
  [[ -n "$OV_PROFILE" ]] && FINAL_PROFILE="$OV_PROFILE"
  log "OVERRIDE recorded: ${OV_ACTOR} chose ${FINAL_HARNESS}/${FINAL_PROFILE} over the recommendation."
  log "  This is provenance only. It grants no bypass: the final fields are validated on their own merits."
fi

TAGS_JSON="$(printf '%s\n' "${TAGS[@]:-}" | jq -R . | jq -sc 'map(select(length > 0))')"
CTX_JSON='null'
[[ -n "$CONTEXT_SIZE" && "$CONTEXT_SIZE" != "null" ]] && CTX_JSON="$CONTEXT_SIZE"

# expires_at is copied UNCHANGED from the accepted decision. Stamping or
# overriding a route never computes a fresh validity window.
jq \
  --arg harness "$FINAL_HARNESS" \
  --arg profile "$FINAL_PROFILE" \
  --arg story "$STORY_ID" \
  --arg title "$TITLE" \
  --argjson tags "$TAGS_JSON" \
  --argjson ctx "$CTX_JSON" \
  --argjson override "$OVERRIDE" \
  --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     harness: $harness,
     model_profile: $profile,
     effort: .effort,
     cost_class: .cost_class,
     entitlement_pool: .entitlement_pool,
     metered: .metered,
     placement_policy: .placement_policy,
     placement_required: .placement_required,
     catalog_version: .catalog_version,
     expires_at: .expires_at,
     task: ({ story_id: $story, tags: $tags }
            + (if $title == "" then {} else {title: $title} end)
            + (if $ctx == null then {} else {context_size: $ctx} end)),
     override: $override,
     created_at: $created
   }
   + (if has("catalog_document_version")
      then {catalog_document_version: .catalog_document_version} else {} end)' \
  "$PROFILE" > "$OUT"

# ---- structural self-check (the closed shape, before anyone dispatches) ----

ALLOWED='["harness","model_profile","effort","cost_class","entitlement_pool","metered","placement_policy","placement_required","catalog_version","catalog_document_version","expires_at","task","override","created_at"]'
REQUIRED='["harness","model_profile","effort","cost_class","entitlement_pool","metered","placement_policy","placement_required","catalog_version","expires_at","task","override"]'

problems="$(jq -r --argjson allowed "$ALLOWED" --argjson required "$REQUIRED" '
  [ ( [keys[]] - $allowed | map("extra property: " + .) )
  , ( $required - [keys[]] | map("missing required property: " + .) )
  , ( if (.effort | IN("low","medium","high","xhigh")) then [] else ["effort not in the closed set: " + (.effort|tostring)] end )
  , ( if (.cost_class == "metered") == (.metered == true) then []
      else ["metered/cost_class dual-key mismatch — spend without stated intent, or the reverse"] end )
  , ( if (.expires_at | type) == "string" and (.expires_at | length) > 0 then [] else ["expires_at is missing or empty"] end )
  , ( if (.task.story_id | type) == "string" and (.task.story_id | length) > 0 then [] else ["task.story_id is empty"] end )
  ] | flatten | .[]' "$OUT")"

if [[ -n "$problems" ]]; then
  log "the generated stamp is not well-formed:"
  printf '  %s\n' "$problems" >&2
  rm -f "$OUT"
  exit 1
fi

# expires_at must be byte-identical to the decision's own.
if [[ "$(jq -r '.expires_at' "$OUT")" != "$(jq -r '.expires_at' "$PROFILE")" ]]; then
  rm -f "$OUT"; die "expires_at was not copied verbatim — refusing to mint a fresh validity window"
fi

log "wrote $OUT"
log "  $FINAL_HARNESS $FINAL_PROFILE effort=$(jq -r .effort "$OUT") cost=$(jq -r .cost_class "$OUT")"
log "  placement_required=$(jq -r .placement_required "$OUT") expires_at=$(jq -r .expires_at "$OUT")"
log "  digest sha256:$(sha256_of "$OUT")"

if (( CHECK )); then
  validator="${AGENT_STAMP_VALIDATE:-agent-stamp-validate}"
  catalog="${AGENT_STAMP_VALIDATE_CATALOG_PATH:-$(yq_cfg '.launcher.catalog_path')}"
  if command -v "$validator" >/dev/null && [[ -n "$catalog" && -f "$catalog" ]]; then
    rc=0
    "$validator" --catalog "$catalog" --stamp "$OUT" > "$TMP/verdict.json" 2>"$TMP/verdict.err" || rc=$?
    case "$rc" in
      0) log "advisory check: valid now (dispatch re-validates immediately before launch)" ;;
      1) log "advisory check: POLICY-INVALID — dispatch will refuse this stamp:"
         jq -r '.checks[]? | select(.passed==false) | "    \(.name): \(.reason_code) — \(.message)"' \
            "$TMP/verdict.json" >&2 || true ;;
      *) log "advisory check: validator could not run:"; sed 's/^/    /' "$TMP/verdict.err" >&2 || true ;;
    esac
  else
    log "advisory check skipped: no validator binary or catalog configured"
  fi
fi
