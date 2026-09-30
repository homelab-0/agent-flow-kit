#!/usr/bin/env bash
# Close only the exact old terminal named by a durable, ownership-proven intent.
set -euo pipefail
intent="${1:?close intent}"
jq -e 'def s: type=="string" and length>0;
  .schema=="afk-pm-close-intent/1" and .authorized==true and
  (.transition_id|s) and (.old.session|s) and (.old.terminal|s) and
  (.old.harness|s) and (.old.worktree.id|s) and (.old.worktree.path|s)' "$intent" >/dev/null 2>&1 || exit 1
transition="$(jq -r .transition_id "$intent")"; terminal="$(jq -r .old.terminal "$intent")"
worktree_id="$(jq -r .old.worktree.id "$intent")"; worktree_path="$(jq -r .old.worktree.path "$intent")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [[ -r "$here/lib/afk-orca.sh" ]]; then . "$here/lib/afk-orca.sh"; else . "$here/../lib/afk-orca.sh"; fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

atomic_write_verified() { # <path> <json>
  local target="$1" value="$2" tmp
  tmp="$(mktemp "$(dirname -- "$target")/.pm-close.XXXXXX")" || return 1
  printf '%s\n' "$value" >"$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$target" || return 1
  jq -e --argjson expected "$value" '.==$expected' "$target" >/dev/null 2>&1
}

afk_orca_run pm-close-worktree -- worktree show --worktree "path:$worktree_path" --json || exit 1
shown="$AFK_ORCA_OUT"
jq -e 'type=="object" and ((has("ok")|not) or .ok==true) and
  ((has("error")|not) or .error==null)' <<<"$shown" >/dev/null 2>&1 || exit 1
observed_id="$(jq -r '.result.worktree.id // .result.id // .worktree.id // .id // empty' <<<"$shown" 2>/dev/null)"
observed_path="$(jq -r '.result.worktree.path // .result.path // .worktree.path // .path // empty' <<<"$shown" 2>/dev/null)"
observed_path="$(cd "$observed_path" 2>/dev/null && pwd -P || true)"
expected_path="$(cd "$worktree_path" 2>/dev/null && pwd -P || true)"
[[ -n "$observed_id" && "$observed_id" == "$worktree_id" && -n "$expected_path" && "$observed_path" == "$expected_path" ]] || exit 1

terminal_is_exact() { # <terminal-show-json>
  jq -e --arg terminal "$terminal" --arg wi "$observed_id" --arg wp "$observed_path" '
    select(type=="object" and ((has("ok")|not) or .ok==true) and
      ((has("error")|not) or .error==null)) |
    (.result.terminal // .terminal // empty) |
    .handle==$terminal and (.worktreeId // .worktree.id // "")==$wi and
    (.worktreePath // .worktree.path // "")==$wp' <<<"$1" >/dev/null 2>&1
}

# `terminal show` is the handle-specific half of the close proof. Orca returns
# a structured stale-handle error after a terminal has been released. A timeout,
# transport failure, auth failure, or malformed response is not absence.
terminal_show_json=""
terminal_show_rc=0
observe_terminal_show() {
  terminal_show_json=""
  terminal_show_rc=0
  afk_orca_run pm-close-show -- terminal show --terminal "$terminal" --json || terminal_show_rc=1
  terminal_show_json="$AFK_ORCA_OUT"
}
terminal_show_is_released() {
  (( terminal_show_rc != 0 )) &&
    jq -e '
      type=="object" and .ok==false and (.error|type)=="object" and
      .error.code=="terminal_handle_stale" and
      ((has("result")|not) or .result==null) and
      ((has("terminal")|not) or .terminal==null)' <<<"$terminal_show_json" >/dev/null 2>&1
}
# The release proof holds only inside the runtime that issued the handle: after
# an Orca restart every old handle is absent and answers terminal_handle_stale
# while its process may still run (AD-28 R5).
runtime_of() { jq -r '._meta.runtimeId // empty | strings' <<<"$1" 2>/dev/null; }
terminal_list_is_well_formed() { # <terminal-list-json>
  jq -e '
    type=="object" and
    ((has("ok")|not) or .ok==true) and
    ((has("error")|not) or .error==null) and
    (.result|type)=="object" and
    (.result.terminals|type)=="array" and
    all(.result.terminals[];
      if type=="object" then
        if (.handle|type)=="string" and (.title|type)=="string" then
          (.handle|length)>0 and (.title|length)>0
        else false end
      else false end)' <<<"$1" >/dev/null 2>&1
}

# Persist the exact handle/worktree binding before the globally addressed
# close. If the process dies after Orca accepts the close, this is the durable
# authority a replay combines with two fresh absence observations.
binding_file="$(dirname -- "$intent")/close-binding.json"
intent_sha="sha256:$(sha256_file "$intent")"
binding="$(jq -nc --arg id "$transition" --arg terminal "$terminal" --arg wi "$observed_id" \
  --arg wp "$observed_path" --arg intent_sha "$intent_sha" \
  '{schema:"afk-pm-close-binding/1",transition_id:$id,terminal:$terminal,
    worktree:{id:$wi,path:$wp},intent_sha256:$intent_sha}')" || exit 1
binding_preexisting=false
proof_runtime=""
if [[ -f "$binding_file" ]]; then
  # A binding written before runtime ids were recorded has none; it can still
  # drive a live close below, but never the recovered-absence branch.
  jq -e --argjson expected "$binding" 'del(.runtime_id)==$expected' "$binding_file" >/dev/null 2>&1 || exit 1
  proof_runtime="$(jq -r '.runtime_id // empty | strings' "$binding_file" 2>/dev/null)"
  binding_preexisting=true
else
  observe_terminal_show
  (( terminal_show_rc == 0 )) || exit 1
  terminal_is_exact "$terminal_show_json" || exit 1
  proof_runtime="$(runtime_of "$terminal_show_json")"
  [[ -n "$proof_runtime" ]] || exit 1
  binding="$(jq -c --arg rt "$proof_runtime" '. + {runtime_id:$rt}' <<<"$binding")" || exit 1
  atomic_write_verified "$binding_file" "$binding" || exit 1
fi

afk_orca_run --bound 5 pm-close-list -- terminal list --worktree "id:$observed_id" --limit "$AFK_ORCA_LIST_LIMIT" --json || exit 1
listed="$AFK_ORCA_OUT"
terminal_list_is_well_formed "$listed" || exit 1
list_runtime="$(runtime_of "$listed")"
present=false
if jq -e --arg t "$terminal" '.result.terminals[]? | select(.handle==$t)' <<<"$listed" >/dev/null 2>&1; then
  present=true
fi
if [[ "$binding_preexisting" == true ]]; then
  observe_terminal_show
  if (( terminal_show_rc == 0 )); then
    terminal_is_exact "$terminal_show_json" || exit 1
    [[ -n "$proof_runtime" ]] || proof_runtime="$(runtime_of "$terminal_show_json")"
  else
    # A prior verified binding plus independent list/show absence recovers the
    # crash-after-close window without addressing an unproven global handle.
    # Only Orca's explicit released-handle response is absence; arbitrary
    # command failure must never synthesize a close receipt.
    [[ "$present" == false ]] || exit 1
    terminal_show_is_released || exit 1
    [[ -n "$proof_runtime" && "$list_runtime" == "$proof_runtime" &&
      "$(runtime_of "$terminal_show_json")" == "$proof_runtime" ]] || exit 1
    jq -nc --arg id "$transition" --arg terminal "$terminal" --arg wi "$observed_id" --arg wp "$observed_path" \
      '{schema:"afk-pm-close-receipt/2",transition_id:$id,terminal:$terminal,closed:true,
        worktree:{id:$wi,path:$wp},observed_before:false,close_requested:true,
        reobserved_absent:true,recovered_after_close:true}'
    exit 0
  fi
fi
# Absence before the request proves nothing. Request the durable whole-tab
# close even on that path; only an accepted request followed by re-observed
# absence is evidence the transition may consume.
afk_orca_run pm-close-close -- terminal close --terminal "$terminal" --tab --json || exit 1
afk_orca_run --bound 5 pm-close-list -- terminal list --worktree "id:$observed_id" --limit "$AFK_ORCA_LIST_LIMIT" --json || exit 1
listed="$AFK_ORCA_OUT"
terminal_list_is_well_formed "$listed" || exit 1
jq -e --arg t "$terminal" '[.result.terminals[]? | select(.handle==$t)]|length==0' <<<"$listed" >/dev/null 2>&1 || exit 1
observe_terminal_show
terminal_show_is_released || exit 1
[[ -n "$proof_runtime" && "$(runtime_of "$listed")" == "$proof_runtime" &&
  "$(runtime_of "$terminal_show_json")" == "$proof_runtime" ]] || exit 1
jq -nc --arg id "$transition" --arg terminal "$terminal" --arg wi "$observed_id" --arg wp "$observed_path" --argjson before "$present" \
  '{schema:"afk-pm-close-receipt/2",transition_id:$id,terminal:$terminal,closed:true,
    worktree:{id:$wi,path:$wp},
    observed_before:$before,close_requested:true,reobserved_absent:true,
    recovered_after_close:($before|not)}'
