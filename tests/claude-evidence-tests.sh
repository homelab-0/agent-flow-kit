#!/usr/bin/env bash
# Offline contract tests for verify-claude-evidence.sh. Every input is a local
# fixture or a mutation of one; harness, credential and network commands are
# replaced with tripwires and must remain untouched.

# shellcheck disable=SC2016
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$KIT_ROOT/files/model-router/scripts/verify-claude-evidence.sh"
RESULT_FIXTURE="$KIT_ROOT/tests/fixtures/claude-evidence-result.json"
EXPECT_FIXTURE="$KIT_ROOT/tests/fixtures/claude-evidence-expectations.json"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
ok() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

run_case() { # <name> <result> <expectations> <exit> <verdict> <reason-or-empty>
  local name="$1" result="$2" expectations="$3" expected_rc="$4"
  local expected_verdict="$5" expected_reason="$6" out rc
  out="$(PATH="$TMPROOT/tripwire:$PATH" "$VERIFY" "$result" "$expectations" 2>"$TMPROOT/err")"
  rc=$?
  assert_eq "$name: exit" "$rc" "$expected_rc"
  if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    bad "$name: machine JSON" "$(head -1 "$TMPROOT/err")"
    return
  fi
  assert_eq "$name: verdict" "$(jq -r .verdict <<<"$out")" "$expected_verdict"
  if [[ -n "$expected_reason" ]]; then
    assert_eq "$name: reason" \
      "$(jq -r --arg reason "$expected_reason" '.reasons | index($reason) != null' <<<"$out")" \
      "true"
  else
    assert_eq "$name: no refusal reasons" "$(jq -r '.reasons | length' <<<"$out")" "0"
  fi
  printf '%s\n' "$out" > "$TMPROOT/last-output.json"
}

mkdir -p "$TMPROOT/tripwire"
for command_name in claude codex curl op; do
  printf '#!/usr/bin/env bash\nprintf invoked > %s\nexit 91\n' \
    "$TMPROOT/tripwire-invoked" > "$TMPROOT/tripwire/$command_name"
  chmod +x "$TMPROOT/tripwire/$command_name"
done

run_case "bound primary and declared auxiliary" "$RESULT_FIXTURE" "$EXPECT_FIXTURE" \
  0 QUALIFIED ""
first_output="$(cat "$TMPROOT/last-output.json")"
assert_eq "qualified output schema version" \
  "$(jq -r .schema_version <<<"$first_output")" "1.0"
assert_eq "qualified output kind" \
  "$(jq -r .kind <<<"$first_output")" "claude_evidence_qualification"
assert_eq "qualified evidence entry count" \
  "$(jq -r .evidence.model_usage_entries <<<"$first_output")" "2"
assert_eq "qualified evidence primary count" \
  "$(jq -r .evidence.primary_occurrences <<<"$first_output")" "1"
run_case "deterministic repeat" "$RESULT_FIXTURE" "$EXPECT_FIXTURE" 0 QUALIFIED ""
assert_eq "deterministic byte-identical output" "$(cat "$TMPROOT/last-output.json")" "$first_output"
assert_eq "cost fields are explicitly not evaluated" \
  "$(jq -r .cost_fields_evaluated <<<"$first_output")" "false"
assert_eq "external facts remain NOT_EVALUATED" \
  "$(jq -r '[.external_facts[] == "NOT_EVALUATED"] | all' <<<"$first_output")" "true"
assert_eq "all five external facts are present" \
  "$(jq -r '.external_facts | length' <<<"$first_output")" "5"

jq '(.modelUsage[] | .costUSD) = 123456789' "$RESULT_FIXTURE" \
  > "$TMPROOT/different-cost.json"
run_case "cost changes do not change qualification" "$TMPROOT/different-cost.json" \
  "$EXPECT_FIXTURE" 0 QUALIFIED ""
assert_eq "cost changes do not change bounded output" \
  "$(cat "$TMPROOT/last-output.json")" "$first_output"

sentinel="secret-result-payload-must-not-escape"
jq --arg sentinel "$sentinel" '.result = $sentinel' "$RESULT_FIXTURE" \
  > "$TMPROOT/sentinel-result.json"
run_case "unrelated result payload is ignored" "$TMPROOT/sentinel-result.json" \
  "$EXPECT_FIXTURE" 0 QUALIFIED ""
if [[ "$(cat "$TMPROOT/last-output.json")" == *"$sentinel"* ]]; then
  bad "result payload is never copied" "sentinel escaped into verifier output"
else
  ok "result payload is never copied"
fi

jq 'del(.modelUsage["claude-haiku-4-5"])' "$RESULT_FIXTURE" > "$TMPROOT/primary-only.json"
jq '.primary_model = "claude-opus-5" | del(.primary_model_usage_key)' \
  "$EXPECT_FIXTURE" > "$TMPROOT/exact-expect.json"
run_case "exact primary needs no alias binding" "$TMPROOT/primary-only.json" \
  "$TMPROOT/exact-expect.json" 0 QUALIFIED ""

jq 'del(.primary_model_usage_key)' "$EXPECT_FIXTURE" > "$TMPROOT/unbound-expect.json"
run_case "unresolved alias is ambiguous" "$RESULT_FIXTURE" "$TMPROOT/unbound-expect.json" \
  1 REFUSED PRIMARY_MODEL_MISSING

jq '.primary_model_usage_key = "claude-opus-missing"' "$EXPECT_FIXTURE" \
  > "$TMPROOT/missing-primary-expect.json"
run_case "explicit binding must be present" "$RESULT_FIXTURE" \
  "$TMPROOT/missing-primary-expect.json" 1 REFUSED PRIMARY_MODEL_MISSING

jq '.modelUsage.opus = .modelUsage["claude-opus-5"]' "$RESULT_FIXTURE" \
  > "$TMPROOT/duplicate-primary.json"
run_case "bound alias plus resolved key is duplicate primary evidence" \
  "$TMPROOT/duplicate-primary.json" "$EXPECT_FIXTURE" \
  1 REFUSED PRIMARY_MODEL_DUPLICATE

jq '.modelUsage["undeclared-model"] = {provider:"firstParty", contextWindow:200000}' \
  "$RESULT_FIXTURE" > "$TMPROOT/unexpected-model.json"
run_case "undeclared model is refused" "$TMPROOT/unexpected-model.json" "$EXPECT_FIXTURE" \
  1 REFUSED UNEXPECTED_MODEL_ENTRY

jq 'del(.modelUsage["claude-haiku-4-5"].provider)' "$RESULT_FIXTURE" \
  > "$TMPROOT/provider-missing.json"
run_case "provider missing" "$TMPROOT/provider-missing.json" "$EXPECT_FIXTURE" \
  1 REFUSED PROVIDER_MISSING

jq '.modelUsage["claude-haiku-4-5"].provider = "thirdParty"' "$RESULT_FIXTURE" \
  > "$TMPROOT/provider-mismatch.json"
run_case "provider mismatch" "$TMPROOT/provider-mismatch.json" "$EXPECT_FIXTURE" \
  1 REFUSED PROVIDER_MISMATCH

jq 'del(.modelUsage["claude-opus-5"].provider)' "$RESULT_FIXTURE" \
  > "$TMPROOT/primary-provider-missing.json"
run_case "primary provider missing" "$TMPROOT/primary-provider-missing.json" \
  "$EXPECT_FIXTURE" 1 REFUSED PROVIDER_MISSING

jq '.modelUsage["claude-opus-5"].provider = "thirdParty"' "$RESULT_FIXTURE" \
  > "$TMPROOT/primary-provider-mismatch.json"
run_case "primary provider mismatch" "$TMPROOT/primary-provider-mismatch.json" \
  "$EXPECT_FIXTURE" 1 REFUSED PROVIDER_MISMATCH

jq 'del(.modelUsage["claude-opus-5"].contextWindow)' "$RESULT_FIXTURE" \
  > "$TMPROOT/window-missing.json"
run_case "window missing" "$TMPROOT/window-missing.json" "$EXPECT_FIXTURE" \
  1 REFUSED CONTEXT_WINDOW_MISSING

jq '.modelUsage["claude-opus-5"].contextWindow = "200000"' "$RESULT_FIXTURE" \
  > "$TMPROOT/window-invalid.json"
run_case "window nonnumeric" "$TMPROOT/window-invalid.json" "$EXPECT_FIXTURE" \
  1 REFUSED CONTEXT_WINDOW_INVALID

jq '.modelUsage["claude-opus-5"].contextWindow = 0' "$RESULT_FIXTURE" \
  > "$TMPROOT/window-nonpositive.json"
run_case "window nonpositive" "$TMPROOT/window-nonpositive.json" "$EXPECT_FIXTURE" \
  1 REFUSED CONTEXT_WINDOW_INVALID

jq '.modelUsage["claude-opus-5"].contextWindow = 149999' "$RESULT_FIXTURE" \
  > "$TMPROOT/window-small.json"
run_case "window below explicit floor" "$TMPROOT/window-small.json" "$EXPECT_FIXTURE" \
  1 REFUSED CONTEXT_WINDOW_INSUFFICIENT
assert_eq "floor is explicit requirement plus headroom" \
  "$(jq -r .evidence.context_floor_tokens "$TMPROOT/last-output.json")" "150000"

jq 'del(.modelUsage["claude-haiku-4-5"].contextWindow)' "$RESULT_FIXTURE" \
  > "$TMPROOT/aux-window-missing.json"
run_case "auxiliary window missing" "$TMPROOT/aux-window-missing.json" \
  "$EXPECT_FIXTURE" 1 REFUSED CONTEXT_WINDOW_MISSING

jq '.modelUsage["claude-haiku-4-5"].contextWindow = 0' "$RESULT_FIXTURE" \
  > "$TMPROOT/aux-window-invalid.json"
run_case "auxiliary window nonpositive" "$TMPROOT/aux-window-invalid.json" \
  "$EXPECT_FIXTURE" 1 REFUSED CONTEXT_WINDOW_INVALID

jq '.modelUsage["claude-haiku-4-5"].contextWindow = 149999' "$RESULT_FIXTURE" \
  > "$TMPROOT/aux-window-small.json"
run_case "auxiliary window below explicit floor" "$TMPROOT/aux-window-small.json" \
  "$EXPECT_FIXTURE" 1 REFUSED CONTEXT_WINDOW_INSUFFICIENT

jq '.modelUsage = []' "$RESULT_FIXTURE" > "$TMPROOT/usage-malformed.json"
run_case "modelUsage malformed" "$TMPROOT/usage-malformed.json" "$EXPECT_FIXTURE" \
  1 REFUSED MODEL_USAGE_MALFORMED

printf '%s\n' 'false' > "$TMPROOT/false-result.json"
run_case "valid scalar result is structurally malformed" "$TMPROOT/false-result.json" \
  "$EXPECT_FIXTURE" 1 REFUSED MODEL_USAGE_MALFORMED

printf '%s\n' '[]' > "$TMPROOT/root-array-result.json"
run_case "valid array result is structurally malformed" "$TMPROOT/root-array-result.json" \
  "$EXPECT_FIXTURE" 1 REFUSED MODEL_USAGE_MALFORMED

printf '%s\n%s\n' "$(jq -c . "$RESULT_FIXTURE")" "$(jq -c . "$RESULT_FIXTURE")" \
  > "$TMPROOT/result-stream.json"
run_case "multiple result documents are refused" "$TMPROOT/result-stream.json" \
  "$EXPECT_FIXTURE" 1 REFUSED RESULT_INVALID_JSON

printf '{bad json\n' > "$TMPROOT/bad-result.json"
run_case "result invalid JSON" "$TMPROOT/bad-result.json" "$EXPECT_FIXTURE" \
  1 REFUSED RESULT_INVALID_JSON
run_case "result unreadable" "$TMPROOT/does-not-exist.json" "$EXPECT_FIXTURE" \
  1 REFUSED RESULT_UNREADABLE

printf '{bad json\n' > "$TMPROOT/bad-expectations.json"
run_case "expectations invalid JSON" "$RESULT_FIXTURE" "$TMPROOT/bad-expectations.json" \
  1 REFUSED EXPECTATIONS_INVALID_JSON
run_case "expectations unreadable" "$RESULT_FIXTURE" "$TMPROOT/no-expectations.json" \
  1 REFUSED EXPECTATIONS_UNREADABLE

printf '%s\n' 'false' > "$TMPROOT/false-expectations.json"
run_case "valid scalar expectations have unsupported schema" "$RESULT_FIXTURE" \
  "$TMPROOT/false-expectations.json" 1 REFUSED EXPECTATIONS_SCHEMA_UNSUPPORTED

printf '%s\n%s\n' "$(jq -c . "$EXPECT_FIXTURE")" "$(jq -c . "$EXPECT_FIXTURE")" \
  > "$TMPROOT/expectations-stream.json"
run_case "multiple expectation documents are refused" "$RESULT_FIXTURE" \
  "$TMPROOT/expectations-stream.json" 1 REFUSED EXPECTATIONS_INVALID_JSON

jq '.schema = "unknown/schema"' "$EXPECT_FIXTURE" > "$TMPROOT/schema-unknown.json"
run_case "expectations schema is closed" "$RESULT_FIXTURE" "$TMPROOT/schema-unknown.json" \
  1 REFUSED EXPECTATIONS_SCHEMA_UNSUPPORTED

jq '.unexpected = true' "$EXPECT_FIXTURE" > "$TMPROOT/expectation-extra.json"
run_case "unknown expectation member" "$RESULT_FIXTURE" "$TMPROOT/expectation-extra.json" \
  1 REFUSED EXPECTATIONS_INVALID

jq '.allowed_auxiliary_models += ["claude-haiku-4-5"]' "$EXPECT_FIXTURE" \
  > "$TMPROOT/duplicate-aux.json"
run_case "duplicate auxiliary declaration" "$RESULT_FIXTURE" "$TMPROOT/duplicate-aux.json" \
  1 REFUSED EXPECTATIONS_INVALID

jq '.allowed_auxiliary_models += [.primary_model]' "$EXPECT_FIXTURE" \
  > "$TMPROOT/primary-alias-as-aux.json"
run_case "primary alias cannot also be auxiliary" "$RESULT_FIXTURE" \
  "$TMPROOT/primary-alias-as-aux.json" 1 REFUSED EXPECTATIONS_INVALID

numeric_cases=(
  'required-zero|.required_context_tokens = 0'
  'required-negative|.required_context_tokens = -1'
  'required-fractional|.required_context_tokens = 1.5'
  'required-nonnumeric|.required_context_tokens = "100000"'
  'required-missing|del(.required_context_tokens)'
  'headroom-negative|.headroom_tokens = -1'
  'headroom-fractional|.headroom_tokens = 1.5'
  'headroom-nonnumeric|.headroom_tokens = "50000"'
  'headroom-missing|del(.headroom_tokens)'
)
for numeric_case in "${numeric_cases[@]}"; do
  numeric_name="${numeric_case%%|*}"
  numeric_filter="${numeric_case#*|}"
  jq "$numeric_filter" "$EXPECT_FIXTURE" > "$TMPROOT/$numeric_name.json"
  run_case "invalid numeric expectation: $numeric_name" "$RESULT_FIXTURE" \
    "$TMPROOT/$numeric_name.json" 1 REFUSED EXPECTATIONS_INVALID
done

mkfifo "$TMPROOT/result.fifo" "$TMPROOT/expectations.fifo"
run_case "result input must be a regular file" "$TMPROOT/result.fifo" \
  "$EXPECT_FIXTURE" 1 REFUSED RESULT_UNREADABLE
run_case "expectations input must be a regular file" "$RESULT_FIXTURE" \
  "$TMPROOT/expectations.fifo" 1 REFUSED EXPECTATIONS_UNREADABLE

assert_eq "no harness, credential, or network command invoked" \
  "$([[ -e "$TMPROOT/tripwire-invoked" ]] && printf yes || printf no)" "no"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
