#!/usr/bin/env bash
# Idempotently create (or rediscover) the one Orca terminal for a PM handoff.
set -euo pipefail
intent="${1:?bootstrap intent}"; transition="${2:?transition id}"
jq -e --arg id "$transition" 'def s: type=="string" and length>0;
  .schema=="afk-pm-bootstrap-intent/1" and .transition_id==$id and
  (.harness|IN("claude","codex","opencode")) and (.worktree.id|s) and
  (.worktree.path|s) and (.pm_dir|s) and (.resume_instruction|s) and
  (.continuation_sha256|s)' "$intent" >/dev/null 2>&1 || exit 1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [[ -r "$here/lib/afk-orca.sh" ]]; then . "$here/lib/afk-orca.sh"; else . "$here/../lib/afk-orca.sh"; fi
worktree_id="$(jq -r .worktree.id "$intent")"; worktree_path="$(jq -r .worktree.path "$intent")"
harness="$(jq -r .harness "$intent")"; run_id="$(jq -r '.run_id // empty' "$intent")"
pm_dir="$(jq -r .pm_dir "$intent")"; continuation_sha="$(jq -r .continuation_sha256 "$intent")"

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

atomic_write_verified() { # <path> <json>
  local target="$1" value="$2" tmp
  mkdir -p -- "$(dirname -- "$target")" || return 1
  chmod 700 -- "$(dirname -- "$target")" || return 1
  tmp="$(mktemp "$(dirname -- "$target")/.pm-launch.XXXXXX")" || return 1
  printf '%s\n' "$value" >"$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$target" || return 1
  jq -e --argjson expected "$value" '.==$expected' "$target" >/dev/null 2>&1
}

terminal_list_valid() { # <terminal-list-json>
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

terminal_show_released() { # <terminal-show-json>
  jq -e '
    type=="object" and .ok==false and (.error|type)=="object" and
    .error.code=="terminal_handle_stale" and
    ((has("result")|not) or .result==null) and
    ((has("terminal")|not) or .terminal==null)' <<<"$1" >/dev/null 2>&1
}

terminal_observe() { # <handle> <title>
  local shown
  afk_orca_run pm-successor-show -- terminal show --terminal "$1" --json || return 1
  shown="$AFK_ORCA_OUT"
  jq -ce --arg handle "$1" --arg title "$2" --arg wi "$observed_id" --arg wp "$observed_path" '
    select(type=="object" and ((has("ok")|not) or .ok==true) and
      ((has("error")|not) or .error==null)) |
    (.result.terminal // .terminal // empty) |
    select(.handle==$handle and .title==$title and
      (.worktreeId // .worktree.id // "")==$wi and
      (.worktreePath // .worktree.path // "")==$wp)' <<<"$shown" 2>/dev/null
}

terminal_live() {
  jq -e 'if has("connected") then .connected==true and (.orphaned // false)==false
    else ((.status // "")|ascii_downcase|IN("running","active","idle","waiting","awaiting_answer","busy","ready","connected")) end' \
    <<<"$1" >/dev/null 2>&1
}

# ORCA-2: orphaned:true alone stops counting as dead (AD-28 R5).
terminal_dead() {
  jq -e 'if has("connected") then .connected==false or (.orphaned // false)==true
    else ((.status // "")|ascii_downcase|IN("exited","closed","dead","failed","terminated","stopped","complete","completed")) end' \
    <<<"$1" >/dev/null 2>&1
}

close_bound_terminal() { # <handle> <title> <binding-file> <receipt-file> <binding-json>
  local listed shown show_rc=0 observed_terminal close_receipt
  close_receipt="$(jq -c '.schema="afk-pm-replacement-receipt/1" |
    . + {closed:true,reobserved_absent:true}' <<<"$5")" || return 1
  if [[ -f "$3" ]]; then
    jq -e --argjson expected "$5" '.==$expected' "$3" >/dev/null 2>&1 || return 1
  else
    observed_terminal="$(terminal_observe "$1" "$2")" || return 1
    terminal_dead "$observed_terminal" || return 1
    atomic_write_verified "$3" "$5" || return 1
  fi
  if [[ -f "$4" ]]; then
    jq -e --argjson expected "$close_receipt" '.==$expected' "$4" >/dev/null 2>&1 || return 1
    return 0
  fi
  afk_orca_run --bound 5 pm-successor-list -- terminal list --worktree "id:$observed_id" --json || return 1
  listed="$AFK_ORCA_OUT"
  terminal_list_valid "$listed" || return 1
  if ! jq -e --arg handle "$1" '.result.terminals[]? | select(.handle==$handle)' \
    <<<"$listed" >/dev/null 2>&1; then
    afk_orca_run pm-successor-show -- terminal show --terminal "$1" --json || show_rc=1
    shown="$AFK_ORCA_OUT"
    if (( show_rc != 0 )); then
      terminal_show_released "$shown" || return 1
      atomic_write_verified "$4" "$close_receipt"
      return
    fi
  fi
  # Re-check both exact binding and dead state at the destructive boundary.
  # The caller's earlier dead observation may have raced a reconnect.
  observed_terminal="$(terminal_observe "$1" "$2")" || return 1
  terminal_dead "$observed_terminal" || return 1
  afk_orca_run pm-successor-close -- terminal close --terminal "$1" --tab --json || return 1
  afk_orca_run --bound 5 pm-successor-list -- terminal list --worktree "id:$observed_id" --json || return 1
  listed="$AFK_ORCA_OUT"
  terminal_list_valid "$listed" || return 1
  jq -e --arg handle "$1" '[.result.terminals[]? | select(.handle==$handle)]|length==0' \
    <<<"$listed" >/dev/null 2>&1 || return 1
  afk_orca_run pm-successor-show -- terminal show --terminal "$1" --json || show_rc=1
  shown="$AFK_ORCA_OUT"
  (( show_rc != 0 )) && terminal_show_released "$shown" || return 1
  atomic_write_verified "$4" "$close_receipt"
}

afk_orca_run pm-successor-worktree -- worktree show --worktree "path:$worktree_path" --json || exit 1
shown="$AFK_ORCA_OUT"
jq -e 'type=="object" and ((has("ok")|not) or .ok==true) and
  ((has("error")|not) or .error==null)' <<<"$shown" >/dev/null 2>&1 || exit 1
observed_id="$(jq -r '.result.worktree.id // .result.id // .worktree.id // .id // empty' <<<"$shown" 2>/dev/null)"
observed_path="$(jq -r '.result.worktree.path // .result.path // .worktree.path // .path // empty' <<<"$shown" 2>/dev/null)"
observed_path="$(cd "$observed_path" 2>/dev/null && pwd -P || true)"
expected_path="$(cd "$worktree_path" 2>/dev/null && pwd -P || true)"
[[ -n "$observed_id" && "$observed_id" == "$worktree_id" && -n "$expected_path" && "$observed_path" == "$expected_path" ]] || exit 1

bootstrap="${AFK_PM_BOOTSTRAP_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orca-pm-bootstrap.sh}"
[[ -x "$bootstrap" ]] || exit 1
printf -v command '%q --intent %q' "$bootstrap" "$intent"
command_sha="sha256:$(printf '%s' "$command" | sha256_text)"
create_id="sha256:$(printf '%s\0%s\0%s\0%s\0%s' "$transition" "$continuation_sha" "$observed_id" "$observed_path" "$command_sha" | sha256_text)"
title="AFK PM successor $transition [afk:${create_id#sha256:}]"
receipt_file="$pm_dir/transitions/$transition/launch-create.json"
attempt_file="$pm_dir/transitions/$transition/launch-attempt.json"
replacement_binding_file="$pm_dir/transitions/$transition/replacement-close-binding.json"
replacement_receipt_file="$pm_dir/transitions/$transition/replacement-close-receipt.json"
replacement_attempt_file="$pm_dir/transitions/$transition/replacement-create-attempt.json"
replacement_consumed_file="$pm_dir/transitions/$transition/replacement-consumed.json"
expected_common="$(jq -nc --arg id "$transition" --arg h "$harness" --arg wi "$observed_id" --arg wp "$observed_path" \
  --arg run "$run_id" --arg title "$title" --arg continuation "$continuation_sha" --arg command_sha "$command_sha" --arg create_id "$create_id" \
  '{schema:"afk-pm-launch-create/1",transition_id:$id,harness:$h,worktree:{id:$wi,path:$wp},
    run_id:(if $run=="" then null else $run end),title:$title,continuation_sha256:$continuation,
    command_sha256:$command_sha,create_id:$create_id}')" || exit 1
expected_attempt="$(jq -nc --argjson common "$expected_common" '$common|.schema="afk-pm-launch-attempt/1"')" || exit 1
if [[ -f "$attempt_file" ]]; then
  jq -e --argjson expected "$expected_attempt" '.==$expected' "$attempt_file" >/dev/null 2>&1 || exit 1
fi
replacement_authorized=false
replacement_generation=""

replacement_binding_for() { # <source-terminal> <source-generation>
  jq -c --arg terminal "$1" --argjson source_generation "$2" '
    .schema="afk-pm-replacement-binding/2" |
    .+{terminal:$terminal,source_generation:$source_generation,
      replacement_generation:($source_generation+1)}' <<<"$expected_common"
}

replacement_attempt_for() { # <replacement-binding-json>
  jq -c --argjson binding "$1" '
    .schema="afk-pm-replacement-create-attempt/1" |
    .+{source_terminal:$binding.terminal,source_generation:$binding.source_generation,
      generation:$binding.replacement_generation}' <<<"$expected_common"
}

consume_completed_replacement() { # <current-launch-receipt-json>
  local launch_receipt="$1" binding close_receipt expected_close expected_attempt_record consumed expected_consumed
  if [[ -f "$replacement_consumed_file" ]]; then
    consumed="$(jq -c . "$replacement_consumed_file" 2>/dev/null)" || return 1
    binding="$(jq -c '.binding' <<<"$consumed" 2>/dev/null)" || return 1
  elif [[ -f "$replacement_binding_file" ]]; then
    binding="$(jq -c . "$replacement_binding_file" 2>/dev/null)" || return 1
  else
    [[ ! -e "$replacement_receipt_file" && ! -e "$replacement_attempt_file" ]]
    return
  fi
  jq -e --argjson common "$expected_common" '
    (.terminal|type)=="string" and (.terminal|length)>0 and
    (.source_generation|type)=="number" and (.source_generation|floor)==.source_generation and
    .source_generation>=-1 and .replacement_generation==(.source_generation+1) and
    del(.terminal,.source_generation,.replacement_generation)==($common|.schema="afk-pm-replacement-binding/2")' \
    <<<"$binding" >/dev/null 2>&1 || return 1
  # The journal is active until a durable launch receipt names its exact next
  # generation.  A receipt for the source generation must never consume it.
  jq -e --argjson binding "$binding" '
    (.generation // 0)==$binding.replacement_generation' <<<"$launch_receipt" >/dev/null 2>&1 || return 0
  expected_consumed="$(jq -nc --argjson binding "$binding" \
    --arg terminal "$(jq -r .terminal <<<"$launch_receipt")" \
    --argjson generation "$(jq -r '.generation // 0' <<<"$launch_receipt")" \
    '{schema:"afk-pm-replacement-consumed/1",binding:$binding,
      successor_terminal:$terminal,generation:$generation}')" || return 1
  if [[ -f "$replacement_consumed_file" ]]; then
    jq -e --argjson expected "$expected_consumed" '.==$expected' \
      "$replacement_consumed_file" >/dev/null 2>&1 || return 1
    if [[ -f "$replacement_binding_file" ]]; then
      jq -e --argjson expected "$binding" '.==$expected' \
        "$replacement_binding_file" >/dev/null 2>&1 || return 1
    fi
  else
    [[ -f "$replacement_binding_file" ]] || return 1
  fi
  expected_close="$(jq -c '.schema="afk-pm-replacement-receipt/1" |
    .+{closed:true,reobserved_absent:true}' <<<"$binding")" || return 1
  if [[ -f "$replacement_receipt_file" ]]; then
    close_receipt="$(jq -c . "$replacement_receipt_file" 2>/dev/null)" || return 1
    jq -e --argjson expected "$expected_close" '.==$expected' <<<"$close_receipt" >/dev/null 2>&1 || return 1
  elif [[ ! -f "$replacement_consumed_file" ]]; then
    return 1
  fi
  if [[ -f "$replacement_attempt_file" ]]; then
    expected_attempt_record="$(replacement_attempt_for "$binding")" || return 1
    jq -e --argjson expected "$expected_attempt_record" '.==$expected' \
      "$replacement_attempt_file" >/dev/null 2>&1 || return 1
  elif [[ ! -f "$replacement_consumed_file" ]]; then
    return 1
  fi
  if [[ ! -f "$replacement_consumed_file" ]]; then
    atomic_write_verified "$replacement_consumed_file" "$expected_consumed" || return 1
  fi
  # The consumed marker carries the complete binding while cleanup is partial
  # and is removed last, so every interrupted cleanup remains attributable.
  rm -f -- "$replacement_attempt_file" || return 1
  rm -f -- "$replacement_receipt_file" || return 1
  rm -f -- "$replacement_binding_file" || return 1
  rm -f -- "$replacement_consumed_file" || return 1
}

afk_orca_run --bound 5 pm-successor-list -- terminal list --worktree "id:$observed_id" --json || exit 1
listed="$AFK_ORCA_OUT"
terminal_list_valid "$listed" || exit 1
# ORCA-6: dedupe by the recorded identity tuple, not the title (AD-28 R4).
matches="$(jq -c --arg title "$title" '[.result.terminals[]? | select(.title==$title)]' <<<"$listed" 2>/dev/null)" || exit 1
count="$(jq 'length' <<<"$matches")"; ((count <= 1)) || exit 1
receipt=""
if [[ -f "$receipt_file" ]]; then
  receipt="$(jq -c . "$receipt_file" 2>/dev/null)" || exit 1
  jq -e --argjson expected "$expected_common" '
    del(.terminal,.generation)==$expected and (.terminal|type)=="string" and (.terminal|length)>0 and
    ((.generation // 0)|type)=="number" and ((.generation // 0)|floor)==(.generation // 0) and
    (.generation // 0)>=0' <<<"$receipt" >/dev/null 2>&1 || exit 1
  terminal="$(jq -r .terminal <<<"$receipt")"
  current_generation="$(jq -r '.generation // 0' <<<"$receipt")"
  consume_completed_replacement "$receipt" || exit 1
  if ((count == 1)); then
    [[ "$(jq -r '.[0].handle // empty' <<<"$matches")" == "$terminal" ]] || exit 1
  fi
  replacement_binding="$(replacement_binding_for "$terminal" "$current_generation")" || exit 1
  if ((count == 0)) && [[ -f "$replacement_binding_file" || -f "$replacement_receipt_file" ]]; then
    close_bound_terminal "$terminal" "$title" "$replacement_binding_file" \
      "$replacement_receipt_file" "$replacement_binding" || exit 1
    rm -f -- "$receipt_file"
    count=0; terminal=""; replacement_authorized=true
    replacement_generation="$(jq -r .replacement_generation <<<"$replacement_binding")"
  else
    observed_terminal="$(terminal_observe "$terminal" "$title")" || exit 1
    if terminal_live "$observed_terminal"; then
      count=1
    elif terminal_dead "$observed_terminal"; then
      close_bound_terminal "$terminal" "$title" "$replacement_binding_file" \
        "$replacement_receipt_file" "$replacement_binding" || exit 1
      rm -f -- "$receipt_file"
      count=0; terminal=""; replacement_authorized=true
      replacement_generation="$(jq -r .replacement_generation <<<"$replacement_binding")"
    else
      exit 1
    fi
  fi
elif ((count == 1)); then
  # A persisted create attempt means the title may be the unacknowledged side
  # effect of that exact attempt.  Title visibility is not an idempotency key.
  [[ ! -e "$replacement_attempt_file" ]] || exit 1
  # A matching title is not provenance. It may only be replaced after Orca
  # independently binds the handle to this exact worktree and reports it dead.
  terminal="$(jq -r '.[0].handle // empty' <<<"$matches")"
  [[ -n "$terminal" ]] || exit 1
  observed_terminal="$(terminal_observe "$terminal" "$title")" || exit 1
  terminal_dead "$observed_terminal" || exit 1
  replacement_binding="$(replacement_binding_for "$terminal" -1)" || exit 1
  close_bound_terminal "$terminal" "$title" "$replacement_binding_file" \
    "$replacement_receipt_file" "$replacement_binding" || exit 1
  count=0; terminal=""; replacement_authorized=true
  replacement_generation="$(jq -r .replacement_generation <<<"$replacement_binding")"
elif [[ -f "$replacement_binding_file" || -f "$replacement_receipt_file" ]]; then
  replacement_binding="$(jq -c . "$replacement_binding_file" 2>/dev/null)" || exit 1
  terminal="$(jq -r '.terminal // empty' <<<"$replacement_binding")" || exit 1
  [[ -n "$terminal" ]] || exit 1
  jq -e --argjson expected "$(replacement_binding_for "$terminal" "$(jq -r '.source_generation // empty' <<<"$replacement_binding")")" \
    '.==$expected' <<<"$replacement_binding" >/dev/null 2>&1 || exit 1
  close_bound_terminal "$terminal" "$title" "$replacement_binding_file" \
    "$replacement_receipt_file" "$replacement_binding" || exit 1
  count=0; terminal=""; replacement_authorized=true
  replacement_generation="$(jq -r .replacement_generation <<<"$replacement_binding")"
elif [[ -e "$replacement_attempt_file" || -e "$replacement_consumed_file" ]]; then
  # A partial or unattributed replacement generation never falls back to the
  # initial-create path.
  exit 1
fi
if ((count == 0)); then
  # A durable attempt with no receipt makes an empty list ambiguous: Orca may
  # have created the exact terminal while the scoped index is still lagging.
  if [[ "$replacement_authorized" == true ]]; then
    expected_replacement_attempt="$(replacement_attempt_for "$replacement_binding")" || exit 1
    if [[ -f "$replacement_attempt_file" ]]; then
      jq -e --argjson expected "$expected_replacement_attempt" '.==$expected' \
        "$replacement_attempt_file" >/dev/null 2>&1 || exit 1
      # Orca create may already have taken effect.  Without an attributable
      # create receipt, neither a visible title nor an empty index permits a
      # second create.
      exit 1
    fi
    atomic_write_verified "$replacement_attempt_file" "$expected_replacement_attempt" || exit 1
  else
    [[ ! -e "$replacement_attempt_file" ]] || exit 1
    if [[ -f "$attempt_file" ]]; then exit 1; fi
    atomic_write_verified "$attempt_file" "$expected_attempt" || exit 1
  fi
  afk_orca_run pm-successor-create -- terminal create --worktree "id:$observed_id" --title "$title" --command "$command" --json || exit 1
  created="$AFK_ORCA_OUT"
  terminal="$(jq -r '.result.terminal.handle // .handle // empty' <<<"$created" 2>/dev/null)"
  [[ -n "$terminal" ]] || exit 1
  observed_terminal="$(terminal_observe "$terminal" "$title")" || exit 1
  terminal_live "$observed_terminal" || exit 1
  if [[ "$replacement_authorized" == true ]]; then
    receipt="$(jq -nc --argjson common "$expected_common" --arg terminal "$terminal" \
      --argjson generation "$replacement_generation" '$common+{terminal:$terminal,generation:$generation}')" || exit 1
  else
    receipt="$(jq -nc --argjson common "$expected_common" --arg terminal "$terminal" \
      '$common+{terminal:$terminal,generation:0}')" || exit 1
  fi
  atomic_write_verified "$receipt_file" "$receipt" || exit 1
  consume_completed_replacement "$receipt" || exit 1
fi
[[ -n "$terminal" ]] || exit 1
jq -nc --arg id "$transition" --arg terminal "$terminal" --arg h "$harness" \
  --arg wi "$observed_id" --arg wp "$observed_path" --arg run "$run_id" --arg continuation "$continuation_sha" \
  --arg command_sha "$command_sha" --arg create_id "$create_id" \
  '{schema:"afk-pm-launch-receipt/2",transition_id:$id,accepted:true,terminal:$terminal,
    harness:$h,worktree:{id:$wi,path:$wp},run_id:(if $run=="" then null else $run end),
    continuation_sha256:$continuation,command_sha256:$command_sha,create_id:$create_id}'
