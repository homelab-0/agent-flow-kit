#!/usr/bin/env bash
# verify-claude-evidence.sh — qualify an existing Claude result envelope using
# caller-owned expectations. This program is deliberately offline: it reads two
# files, calls jq, and reports only bounded metadata. It never discovers a
# model, provider, credential, catalog, harness, or network endpoint.

set -uo pipefail

usage() {
  printf 'usage: verify-claude-evidence.sh <result-envelope.json> <expectations.json>\n' >&2
  exit 2
}

emit_refusal() { # <reason-code>
  jq -nc --arg reason "$1" '{
    schema_version:"1.0",
    kind:"claude_evidence_qualification",
    verdict:"REFUSED",
    reasons:[$reason],
    evidence:{
      model_usage_entries:0,
      primary_occurrences:0,
      unexpected_model_entries:0,
      provider_missing_entries:0,
      provider_mismatch_entries:0,
      context_window_missing_entries:0,
      context_window_invalid_entries:0,
      context_window_insufficient_entries:0,
      required_context_tokens:null,
      headroom_tokens:null,
      context_floor_tokens:null,
      minimum_observed_context_window:null
    },
    external_facts:{
      subscription_identity:"NOT_EVALUATED",
      subscription_liveness:"NOT_EVALUATED",
      quota:"NOT_EVALUATED",
      exhaustion:"NOT_EVALUATED",
      paid_extra_usage:"NOT_EVALUATED"
    },
    cost_fields_evaluated:false
  }'
  exit 1
}

[[ $# -eq 2 ]] || usage
RESULT_FILE="$1"
EXPECTATIONS_FILE="$2"

command -v jq >/dev/null 2>&1 || {
  printf 'verify-claude-evidence: jq is required\n' >&2
  exit 2
}

[[ -f "$RESULT_FILE" && -r "$RESULT_FILE" ]] || emit_refusal RESULT_UNREADABLE
[[ -f "$EXPECTATIONS_FILE" && -r "$EXPECTATIONS_FILE" ]] || emit_refusal EXPECTATIONS_UNREADABLE
jq -se 'length == 1' "$RESULT_FILE" >/dev/null 2>&1 || emit_refusal RESULT_INVALID_JSON
jq -se 'length == 1' "$EXPECTATIONS_FILE" >/dev/null 2>&1 || emit_refusal EXPECTATIONS_INVALID_JSON

if ! jq -e 'type == "object" and .schema == "afk-claude-evidence-expectations/1"' \
     "$EXPECTATIONS_FILE" >/dev/null 2>&1; then
  emit_refusal EXPECTATIONS_SCHEMA_UNSUPPORTED
fi

if ! jq -e '
    (keys - ["schema", "provider", "primary_model", "primary_model_usage_key",
             "allowed_auxiliary_models", "required_context_tokens",
             "headroom_tokens"] | length) == 0 and
    (.provider | type == "string" and length > 0) and
    (.primary_model | type == "string" and length > 0) and
    ((.primary_model_usage_key == null) or
      (.primary_model_usage_key | type == "string" and length > 0)) and
    (.allowed_auxiliary_models | type == "array") and
    (all(.allowed_auxiliary_models[];
      type == "string" and length > 0)) and
    ((.allowed_auxiliary_models | unique | length) ==
      (.allowed_auxiliary_models | length)) and
    (.required_context_tokens | type == "number" and
      . > 0 and floor == .) and
    (.headroom_tokens | type == "number" and
      . >= 0 and floor == .) and
    ((.primary_model_usage_key // .primary_model) as $primary |
      (.allowed_auxiliary_models | index($primary)) == null) and
    (.primary_model as $declared_primary |
      (.allowed_auxiliary_models | index($declared_primary)) == null)
  ' "$EXPECTATIONS_FILE" >/dev/null 2>&1; then
  emit_refusal EXPECTATIONS_INVALID
fi

OUTPUT="$(jq -nc --slurpfile result "$RESULT_FILE" \
                 --slurpfile expectations "$EXPECTATIONS_FILE" '
  $result[0] as $result |
  $expectations[0] as $expected |
  ($expected.primary_model_usage_key // $expected.primary_model) as $primary |
  ($expected.primary_model_usage_key != null) as $binding_declared |
  ($expected.required_context_tokens + $expected.headroom_tokens) as $floor |
  (if ($result | type) == "object" then ($result.modelUsage // null)
   else null end) as $usage |
  (($usage | type) == "object" and ($usage | length) > 0) as $usage_valid |
  (if $usage_valid then ($usage | to_entries) else [] end) as $entries |
  ([$entries[] | select(.key == $primary)] | length) as $resolved_primary_count |
  (if $binding_declared and $expected.primary_model != $primary
   then ([$entries[] | select(.key == $expected.primary_model)] | length)
   else 0
   end) as $alias_primary_count |
  ($resolved_primary_count + $alias_primary_count) as $primary_count |
  ([$entries[] |
      .key as $key |
      select(
        $key != $primary and
        (($expected.allowed_auxiliary_models | index($key)) == null)
      )
    ] | length) as $unexpected_count |
  ([$entries[] | select(
      (.value | type) != "object" or
      (.value | has("provider") | not) or
      (.value.provider | type) != "string" or
      (.value.provider | length) == 0
    )] | length) as $provider_missing |
  ([$entries[] | select(
      (.value | type) == "object" and
      (.value.provider | type) == "string" and
      (.value.provider | length) > 0 and
      .value.provider != $expected.provider
    )] | length) as $provider_mismatch |
  ([$entries[] | select(
      (.value | type) != "object" or
      (.value | has("contextWindow") | not) or
      .value.contextWindow == null
    )] | length) as $window_missing |
  ([$entries[] | select(
      (.value | type) == "object" and
      (.value | has("contextWindow")) and
      .value.contextWindow != null and
      ((.value.contextWindow | type) != "number" or
       .value.contextWindow <= 0)
    )] | length) as $window_invalid |
  ([$entries[] | select(
      (.value | type) == "object" and
      (.value.contextWindow | type) == "number" and
      .value.contextWindow > 0 and
      .value.contextWindow < $floor
    )] | length) as $window_insufficient |
  ([$entries[] | .value.contextWindow? |
      select(type == "number" and . > 0)] | min // null) as $minimum_window |
  ([
    (if $usage_valid then empty else "MODEL_USAGE_MALFORMED" end),
    (if $usage_valid and $resolved_primary_count == 0
       then "PRIMARY_MODEL_MISSING" else empty end),
    (if $usage_valid and $primary_count > 1
       then "PRIMARY_MODEL_DUPLICATE" else empty end),
    (if $unexpected_count > 0 then "UNEXPECTED_MODEL_ENTRY" else empty end),
    (if $provider_missing > 0 then "PROVIDER_MISSING" else empty end),
    (if $provider_mismatch > 0 then "PROVIDER_MISMATCH" else empty end),
    (if $window_missing > 0 then "CONTEXT_WINDOW_MISSING" else empty end),
    (if $window_invalid > 0 then "CONTEXT_WINDOW_INVALID" else empty end),
    (if $window_insufficient > 0 then "CONTEXT_WINDOW_INSUFFICIENT" else empty end)
  ]) as $reasons |
  {
    schema_version:"1.0",
    kind:"claude_evidence_qualification",
    verdict:(if ($reasons | length) == 0 then "QUALIFIED" else "REFUSED" end),
    reasons:$reasons,
    evidence:{
      model_usage_entries:($entries | length),
      primary_occurrences:$primary_count,
      unexpected_model_entries:$unexpected_count,
      provider_missing_entries:$provider_missing,
      provider_mismatch_entries:$provider_mismatch,
      context_window_missing_entries:$window_missing,
      context_window_invalid_entries:$window_invalid,
      context_window_insufficient_entries:$window_insufficient,
      required_context_tokens:$expected.required_context_tokens,
      headroom_tokens:$expected.headroom_tokens,
      context_floor_tokens:$floor,
      minimum_observed_context_window:$minimum_window
    },
    external_facts:{
      subscription_identity:"NOT_EVALUATED",
      subscription_liveness:"NOT_EVALUATED",
      quota:"NOT_EVALUATED",
      exhaustion:"NOT_EVALUATED",
      paid_extra_usage:"NOT_EVALUATED"
    },
    cost_fields_evaluated:false
  }
')" || emit_refusal RESULT_EVALUATION_FAILED

printf '%s\n' "$OUTPUT"
[[ "$(jq -r .verdict <<<"$OUTPUT")" == "QUALIFIED" ]]
