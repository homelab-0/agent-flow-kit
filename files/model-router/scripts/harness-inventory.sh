#!/usr/bin/env bash
# Emit a short-lived, non-secret view of exact harness/profile/pool bindings.
# This is exclusion-only availability; routing remains the router's authority.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${AGENT_FLOW_CONFIG:-${SUBSCRIPTIONS_FILE:-$ROUTER_DIR/subscriptions.yaml}}"
BINDINGS_FILE="${AGENT_FLOW_HARNESS_BINDINGS:-$ROUTER_DIR/harness-bindings.yaml}"
MODE="${1:---route}"

log() { printf 'harness-inventory: %s\n' "$*" >&2; }
die() { log "$1"; exit "${2:-1}"; }
cfg() {
  local path="$1" env_name="$2" fallback="$3" value=""
  if [[ -n "${!env_name:-}" ]]; then printf '%s' "${!env_name}"; return; fi
  if [[ -f "$CONFIG_FILE" ]]; then value="$(yq -r "$path // \"\"" "$CONFIG_FILE" 2>/dev/null || true)"; fi
  [[ -n "$value" && "$value" != null ]] && printf '%s' "$value" || printf '%s' "$fallback"
}
passwd_home() {
  local user; user="$(id -un)"
  if command -v getent >/dev/null; then getent passwd "$user" | cut -d: -f6
  else dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}'; fi
}
format_epoch() {
  if date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  else date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; fi
}
resolve_bin() { PATH="$2" command -v -- "$1" 2>/dev/null || true; }
stat_identity() { stat -Lc '%d:%i:%y' "$1" 2>/dev/null || stat -Lf '%d:%i:%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$1" 2>/dev/null; }
stat_mode() { stat -Lc '%a' "$1" 2>/dev/null || stat -Lf '%Lp' "$1" 2>/dev/null; }

for dep in jq yq; do command -v "$dep" >/dev/null || die "missing dependency: $dep" 2; done
[[ "$MODE" == --route || "$MODE" == --full ]] || die "usage: harness-inventory.sh [--route|--full]" 2
[[ -f "$BINDINGS_FILE" ]] || die "binding declarations not found" 2

BINDINGS_DOC="$(yq -o=json '.' "$BINDINGS_FILE" 2>/dev/null)" || die "binding declarations are unreadable"
jq -e 'keys == ["bindings","schema"] and .schema == "afk-harness-bindings/1"' <<<"$BINDINGS_DOC" >/dev/null || die "binding declarations have an unknown or open top-level shape"
BINDINGS_JSON="$(jq -c '.bindings' <<<"$BINDINGS_DOC")"
jq -e '
  type == "array" and length > 0
  and all(.[];
    ((keys - ["auth_kind","auth_provider","cost_class","efforts","entitlement_pool","funding_attestation","harness","launch_class","model_profile","physical_model"]) | length) == 0
    and (.harness|type)=="string" and (.model_profile|type)=="string"
    and has("entitlement_pool") and (.cost_class | IN("free","subscription"))
    and (.launch_class | IN("claude-native","claude-gateway","codex-native","opencode"))
    and (if (.launch_class|startswith("claude-")) then .harness=="claude" elif .launch_class=="codex-native" then .harness=="codex" else .harness=="opencode" end))
  and all(.[] | select(.launch_class!="opencode"); keys == ["cost_class","entitlement_pool","harness","launch_class","model_profile"])
  and all(.[] | select(.launch_class=="opencode");
    (.physical_model|type)=="string" and (.physical_model|length)>0
    and (.auth_provider|type)=="string" and (.auth_provider|length)>0 and (.auth_kind|IN("oauth","api"))
    and ((.funding_attestation? == null) or .funding_attestation=="minimax-token-plan")
    and (.efforts|type)=="object" and (.efforts|length)>0
    and ((.efforts|keys-["low","medium","high","xhigh"])|length)==0
    and (if (.model_profile|endswith("/strong")) then (.efforts|has("high") and has("xhigh"))
         elif (.model_profile|endswith("/standard")) then (.efforts|has("medium"))
         else (.efforts|has("low") and has("medium") and has("high") and has("xhigh")) end)
    and all(.efforts[]; (.model|type)=="string" and (.model|length)>0
      and (.variant|type)=="string" and (.variant|length)>0))
  and ([.[] | [.harness,.model_profile,(.entitlement_pool // "<null>")] | @json] | unique | length) == length
' <<<"$BINDINGS_JSON" >/dev/null || die "binding declarations fail their closed identity checks"

NOW_EPOCH="$(date -u +%s)"; OBSERVED_AT="$(format_epoch "$NOW_EPOCH")"; EXPIRES_AT="$(format_epoch "$((NOW_EPOCH + 300))")"
APPROVED_HOME="$(cfg '.launcher.approved_home' AGENT_FLOW_APPROVED_HOME "$(passwd_home)")"
CONFIGURED_PATH="$(cfg '.launcher.approved_path' AGENT_FLOW_APPROVED_PATH '')"
default_path_for() { local p d=""; p="$(command -v -- "$1" 2>/dev/null || true)"; [[ -n "$p" ]] && d="$(dirname "$p")"; printf '%s' "${d:+$d:}/usr/local/bin:/usr/bin:/bin"; }
CLAUDE_BIN="$(cfg '.launcher.harness_binaries.claude' AFK_CLAUDE_BIN claude)"
CODEX_BIN=codex
OPENCODE_BIN="$(cfg '.launcher.harness_binaries.opencode' AFK_OPENCODE_BIN opencode)"
CLAUDE_PATHS="${CONFIGURED_PATH:-$(default_path_for "$CLAUDE_BIN")}"; CODEX_PATHS="${CONFIGURED_PATH:-$(default_path_for "$CODEX_BIN")}"; OPENCODE_PATHS="${CONFIGURED_PATH:-$(default_path_for "$OPENCODE_BIN")}"; DEVIN_PATHS="${CONFIGURED_PATH:-$(default_path_for devin)}"
APPROVED_USER="$(id -un)"
CODEX_CONFIG_HOME="${CODEX_HOME:-}"; [[ -z "$CODEX_CONFIG_HOME" || ( -d "$CODEX_CONFIG_HOME" && -O "$CODEX_CONFIG_HOME" ) ]] || CODEX_CONFIG_HOME=""
OPENCODE_HOME="$(cfg '.launcher.opencode.approved_home' AGENT_FLOW_OPENCODE_HOME "$APPROVED_HOME")"
OPENCODE_DATA_HOME="$(cfg '.launcher.opencode.data_home' AGENT_FLOW_OPENCODE_DATA_HOME "$OPENCODE_HOME/.local/share")"
EXPECTED_OPENCODE_VERSION="$(cfg '.launcher.opencode.exact_version' AGENT_FLOW_OPENCODE_VERSION 1.18.31)"

PROBE_OUT=""; PROBE_RC=0; PROBE_XDG_DATA_HOME=""; PROBE_CODEX_HOME=""
run_probe() {
  PROBE_OUT=""; PROBE_RC=0
  local probe_home="$1" probe_path="$2" bound=""; shift 2
  command -v timeout >/dev/null && bound=timeout
  [[ -z "$bound" ]] && command -v gtimeout >/dev/null && bound=gtimeout
  [[ -n "$bound" ]] || return 1
  local env_args=(HOME="$probe_home" PATH="$probe_path" USER="$APPROVED_USER" LANG=C.UTF-8 TERM=dumb NO_COLOR=1)
  [[ -n "$PROBE_XDG_DATA_HOME" ]] && env_args+=(XDG_DATA_HOME="$PROBE_XDG_DATA_HOME")
  [[ -n "$PROBE_CODEX_HOME" ]] && env_args+=(CODEX_HOME="$PROBE_CODEX_HOME")
  PROBE_OUT="$(env -i "${env_args[@]}" "$bound" 5 "$@" 2>&1 | head -c 65537)" || PROBE_RC=$?
  (( ${#PROBE_OUT} <= 65536 && PROBE_RC == 0 ))
}

CLAUDE_PATH="$(resolve_bin "$CLAUDE_BIN" "$CLAUDE_PATHS")"; CODEX_PATH="$(resolve_bin "$CODEX_BIN" "$CODEX_PATHS")"; OPENCODE_PATH="$(resolve_bin "$OPENCODE_BIN" "$OPENCODE_PATHS")"; DEVIN_PATH="$(resolve_bin devin "$DEVIN_PATHS")"
CLAUDE_NATIVE_STATE=UNAVAILABLE; CLAUDE_GATEWAY_STATE=UNAVAILABLE; CODEX_NATIVE_STATE=UNAVAILABLE
CLAUDE_CAPABILITY_STATE=ABSENT; CODEX_CAPABILITY_STATE=ABSENT; OPENCODE_CAPABILITY_STATE=ABSENT; OPENCODE_AUTH_STATE=UNAVAILABLE; MINIMAX_OC_ATTESTED=false

if [[ -n "$CLAUDE_PATH" ]]; then
  if run_probe "$APPROVED_HOME" "$CLAUDE_PATHS" "$CLAUDE_PATH" --help; then
    if [[ "$PROBE_OUT" == *--model* && "$PROBE_OUT" == *--permission-mode* && "$PROBE_OUT" == *--strict-mcp-config* && ( "$PROBE_OUT" == *--append-system-prompt-file* || "$PROBE_OUT" == *'--append-system-prompt[-file]'* ) ]]; then
      CLAUDE_CAPABILITY_STATE=COMPATIBLE; run_probe "$APPROVED_HOME" "$CLAUDE_PATHS" "$CLAUDE_PATH" auth status || true
      case "$PROBE_OUT" in *'Not logged in'*|*'not authenticated'*|*expired*) CLAUDE_NATIVE_STATE=UNAVAILABLE ;; *claude.ai*|*firstParty*|*subscription*) [[ "$PROBE_RC" == 0 ]] && CLAUDE_NATIVE_STATE=AVAILABLE || CLAUDE_NATIVE_STATE=UNKNOWN ;; *) CLAUDE_NATIVE_STATE=UNKNOWN ;; esac
    else CLAUDE_CAPABILITY_STATE=INCOMPATIBLE; fi
  else CLAUDE_CAPABILITY_STATE=UNKNOWN; CLAUDE_NATIVE_STATE=UNKNOWN; fi
  if [[ "$CLAUDE_CAPABILITY_STATE" == COMPATIBLE ]]; then
    gateway_url="$(cfg '.launcher.gateway_endpoint' AGENT_FLOW_GATEWAY_URL '')"; token_ref="$(cfg '.launcher.gateway_token_ref' AGENT_FLOW_GATEWAY_TOKEN_REF '')"; op_env_file="$(cfg '.launcher.op_env_file' AGENT_FLOW_OP_ENV_FILE "$APPROVED_HOME/.op-agent-env")"
    [[ -n "$gateway_url" && -n "$token_ref" && -r "$op_env_file" && -n "$(resolve_bin op "$CLAUDE_PATHS")" ]] && CLAUDE_GATEWAY_STATE=AVAILABLE
  elif [[ "$CLAUDE_CAPABILITY_STATE" == UNKNOWN ]]; then CLAUDE_GATEWAY_STATE=UNKNOWN; fi
fi

PROBE_CODEX_HOME="$CODEX_CONFIG_HOME"; CODEX_PROBE_HOME="${HOME:-$(passwd_home)}"; [[ -d "$CODEX_PROBE_HOME" && -O "$CODEX_PROBE_HOME" ]] || CODEX_PROBE_HOME="$(passwd_home)"
if [[ -n "$CODEX_PATH" ]]; then
  if run_probe "$CODEX_PROBE_HOME" "$CODEX_PATHS" "$CODEX_PATH" --help; then
    if [[ "$PROBE_OUT" == *--sandbox* && "$PROBE_OUT" == *--config* && "$PROBE_OUT" == *exec* ]]; then
      CODEX_CAPABILITY_STATE=COMPATIBLE; run_probe "$CODEX_PROBE_HOME" "$CODEX_PATHS" "$CODEX_PATH" login status || true
      case "$PROBE_OUT" in *'Not logged in'*|*'not logged in'*|*expired*) CODEX_NATIVE_STATE=UNAVAILABLE ;; *'Logged in using ChatGPT'*|*ChatGPT*|*chatgpt*) [[ "$PROBE_RC" == 0 ]] && CODEX_NATIVE_STATE=AVAILABLE || CODEX_NATIVE_STATE=UNKNOWN ;; *) CODEX_NATIVE_STATE=UNKNOWN ;; esac
    else CODEX_CAPABILITY_STATE=INCOMPATIBLE; fi
  else CODEX_CAPABILITY_STATE=UNKNOWN; CODEX_NATIVE_STATE=UNKNOWN; fi
fi
PROBE_CODEX_HOME=""

OC_AUTH=""; PROBE_XDG_DATA_HOME="$OPENCODE_DATA_HOME"
if [[ -n "$OPENCODE_PATH" ]]; then
  if run_probe "$OPENCODE_HOME" "$OPENCODE_PATHS" "$OPENCODE_PATH" --version; then [[ "$PROBE_OUT" == "$EXPECTED_OPENCODE_VERSION" ]] && OPENCODE_CAPABILITY_STATE=COMPATIBLE || OPENCODE_CAPABILITY_STATE=INCOMPATIBLE; else OPENCODE_CAPABILITY_STATE=UNKNOWN; fi
  if [[ "$OPENCODE_CAPABILITY_STATE" == COMPATIBLE && -d "$OPENCODE_HOME" && -O "$OPENCODE_HOME" && -d "$OPENCODE_DATA_HOME" && -O "$OPENCODE_DATA_HOME" && -f "$OPENCODE_DATA_HOME/opencode/auth.json" && -O "$OPENCODE_DATA_HOME/opencode/auth.json" ]] && run_probe "$OPENCODE_HOME" "$OPENCODE_PATHS" "$OPENCODE_PATH" auth list --pure; then
    OC_AUTH="$(printf '%s' "$PROBE_OUT" | sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g')"; OPENCODE_AUTH_STATE=OBSERVED
    auth_store="$OPENCODE_DATA_HOME/opencode/auth.json"; attestation="$(cfg '.launcher.opencode.minimax_token_plan_attestation' AGENT_FLOW_OPENCODE_MINIMAX_ATTESTATION "$OPENCODE_DATA_HOME/opencode/afk-minimax-token-plan.attestation.json")"
    expected="$(stat_identity "$auth_store" || true)"; mode="$(stat_mode "$attestation" || true)"; actual="$(jq -er 'select(.schema=="afk-opencode-funding-attestation/1" and .provider=="minimax-cn" and .entitlement_pool=="minimax-max" and .credential_class=="token-plan") | .auth_store_identity' "$attestation" 2>/dev/null || true)"
    [[ -n "$expected" && "$mode" == 600 && "$actual" == "$expected" ]] && MINIMAX_OC_ATTESTED=true
  elif [[ "$OPENCODE_CAPABILITY_STATE" == COMPATIBLE && -f "$OPENCODE_DATA_HOME/opencode/auth.json" && -O "$OPENCODE_DATA_HOME/opencode/auth.json" ]]; then OPENCODE_AUTH_STATE=UNKNOWN; fi
fi
PROBE_XDG_DATA_HOME=""; PROBE_OUT=""

RESULTS=""
while IFS= read -r row; do
  launch_class="$(jq -r .launch_class <<<"$row")"; state=UNAVAILABLE; reason=AUTH_OR_CONFIG_UNAVAILABLE
  case "$launch_class" in
    claude-native) state="$CLAUDE_NATIVE_STATE"; [[ "$state" == AVAILABLE ]] && reason=CONFIGURED_AUTH_RECORD; [[ "$state" == UNKNOWN ]] && reason=AUTH_STATUS_UNPROVEN ;;
    claude-gateway) state="$CLAUDE_GATEWAY_STATE"; [[ "$state" == AVAILABLE ]] && reason=CONFIGURED_GATEWAY_BINDING; [[ "$state" == UNKNOWN ]] && reason=CAPABILITY_UNPROVEN ;;
    codex-native) state="$CODEX_NATIVE_STATE"; [[ "$state" == AVAILABLE ]] && reason=CONFIGURED_AUTH_RECORD; [[ "$state" == UNKNOWN ]] && reason=AUTH_STATUS_UNPROVEN ;;
    opencode)
      provider="$(jq -r '.auth_provider // ""' <<<"$row")"; kind="$(jq -r '.auth_kind // ""' <<<"$row")"; funding="$(jq -r '.funding_attestation // ""' <<<"$row")"; auth_count=0
      [[ "$OPENCODE_AUTH_STATE" == OBSERVED ]] && auth_count="$(grep -F "$provider" <<<"$OC_AUTH" | grep -Ec "[[:space:]]${kind}([[:space:]]|$)" || true)"
      if [[ "$OPENCODE_CAPABILITY_STATE" == UNKNOWN || "$OPENCODE_AUTH_STATE" == UNKNOWN ]]; then state=UNKNOWN; reason=AUTH_STATUS_UNPROVEN
      elif [[ "$auth_count" == 1 && -z "$funding" ]]; then state=AVAILABLE; reason=CONFIGURED_AUTH_RECORD
      elif [[ "$auth_count" == 1 && "$funding" == minimax-token-plan ]] && $MINIMAX_OC_ATTESTED; then state=AVAILABLE; reason=CONFIGURED_FUNDING_ATTESTATION
      fi ;;
  esac
  RESULTS+="$(jq -c --arg state "$state" --arg reason "$reason" '{harness,model_profile,entitlement_pool,cost_class,launch_class} + (if .launch_class=="opencode" then {physical_model,auth_provider,auth_kind,efforts} + (if has("funding_attestation") then {funding_attestation} else {} end) else {} end) + {state:$state,reason:$reason,liveness:"NOT_EVALUATED"}' <<<"$row")"$'\n'
done < <(jq -c '.[]' <<<"$BINDINGS_JSON")
OC_AUTH=""

AVAILABLE="$(printf '%s' "$RESULTS" | jq -sc '[.[] | select(.state=="AVAILABLE") | {harness,model_profile,entitlement_pool}] | sort_by(.harness,.model_profile,(.entitlement_pool // ""))')"
if [[ "$MODE" == --route ]]; then jq -n --arg observed "$OBSERVED_AT" --arg expires "$EXPIRES_AT" --argjson bindings "$AVAILABLE" '{schema:"afk-harness-inventory/1",observed_at:$observed,expires_at:$expires,bindings:$bindings}'; exit 0; fi
jq -n --arg observed "$OBSERVED_AT" --arg expires "$EXPIRES_AT" --arg claude "${CLAUDE_PATH:+PRESENT}" --arg codex "${CODEX_PATH:+PRESENT}" --arg opencode "${OPENCODE_PATH:+PRESENT}" --arg devin "${DEVIN_PATH:+PRESENT}" --arg claude_cap "$CLAUDE_CAPABILITY_STATE" --arg codex_cap "$CODEX_CAPABILITY_STATE" --arg opencode_cap "$OPENCODE_CAPABILITY_STATE" --argjson bindings "$(printf '%s' "$RESULTS" | jq -sc 'sort_by(.harness,.model_profile,(.entitlement_pool // ""))')" '
 {schema:"afk-harness-inventory-report/1",observed_at:$observed,expires_at:$expires,launch_authoritative:false,liveness:"NOT_EVALUATED",
  harnesses:[{name:"claude",binary_state:(if $claude=="" then "ABSENT" else $claude end),adapter_state:"SUPPORTED",capability_state:$claude_cap},{name:"codex",binary_state:(if $codex=="" then "ABSENT" else $codex end),adapter_state:"SUPPORTED",capability_state:$codex_cap},{name:"devin",binary_state:(if $devin=="" then "ABSENT" else $devin end),adapter_state:"UNSUPPORTED",capability_state:"NOT_EVALUATED"},{name:"opencode",binary_state:(if $opencode=="" then "ABSENT" else $opencode end),adapter_state:"SUPPORTED",capability_state:$opencode_cap}],bindings:$bindings}'
