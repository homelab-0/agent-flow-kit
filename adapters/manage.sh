#!/usr/bin/env bash
# Idempotently compose/remove AFK with native harness configuration. Every
# removal is conditional on the AFK value still being present, so later user
# edits and unrelated hooks/plugins survive.
# shellcheck disable=SC1091,SC2034 # sourced modules consume shared transaction state
set -euo pipefail

INVOCATION_CWD="$(pwd -P)"
ACTION="${1:-}"; HARNESS="${2:-}"
shift $(( $# >= 2 ? 2 : $# ))
HOME_ROOT="${HOME:-}"
STATE_DIR="${AFK_STATE_DIR:-${XDG_STATE_HOME:-${HOME_ROOT:+$HOME_ROOT/.local/state}}/agent-flow-kit}"
ADAPTER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_ROOT="$ADAPTER_ROOT"
while (( $# )); do
  case "$1" in
    --home) (( $# >= 2 )) || exit 2; HOME_ROOT="$2"; shift 2 ;;
    --state-dir) (( $# >= 2 )) || exit 2; STATE_DIR="$2"; shift 2 ;;
    --adapter-root) (( $# >= 2 )) || exit 2; ADAPTER_ROOT="$2"; shift 2 ;;
    *) printf 'adapter-manager: unknown option\n' >&2; exit 2 ;;
  esac
done
[[ "$ACTION" == install || "$ACTION" == remove ]] || { printf 'usage: manage.sh install|remove claude|codex|opencode|hermes\n' >&2; exit 2; }
case "$HARNESS" in claude|codex|opencode|hermes) : ;; *) printf 'adapter-manager: unsupported adapter\n' >&2; exit 2 ;; esac
[[ -n "$HOME_ROOT" && -n "$STATE_DIR" ]] || { printf 'adapter-manager: home and state directory must be declared\n' >&2; exit 2; }
[[ "$HOME_ROOT" == /* ]] || HOME_ROOT="$INVOCATION_CWD/$HOME_ROOT"
ADAPTER_ROOT="$(cd "$ADAPTER_ROOT" 2>/dev/null && pwd -P)" || { printf 'adapter-manager: adapter directory is unavailable\n' >&2; exit 2; }
manager_core="$MANAGER_ROOT/manage-core.sh"
manager_transactions="$MANAGER_ROOT/manage-transactions.sh"
if [[ -L "$manager_core" || ! -f "$manager_core" || ! -r "$manager_core" ||
      -L "$manager_transactions" || ! -f "$manager_transactions" || ! -r "$manager_transactions" ]]; then
  printf 'adapter-manager: manager modules are unavailable\n' >&2
  exit 2
fi
# shellcheck source=manage-core.sh
. "$manager_core"
# shellcheck source=manage-transactions.sh
. "$manager_transactions"
mkdir -p -- "$STATE_DIR/adapters"
STATE_DIR="$(cd "$STATE_DIR" 2>/dev/null && pwd -P)" || { printf 'adapter-manager: state directory is unavailable\n' >&2; exit 2; }

record="$STATE_DIR/adapters/$HARNESS.json"
chmod 700 "$STATE_DIR" "$STATE_DIR/adapters" 2>/dev/null || true
manager_lock="$STATE_DIR/adapters/.manage-$HARNESS.lockdir"
manager_lock_owner=""
manager_lock_candidate=""
manager_lock_reclaim="$manager_lock/reclaim"
if ! acquire_manager_lock; then
  printf 'adapter-manager: CONCURRENT_OPERATION\n' >&2; exit 3
fi
trap release_manager_lock EXIT

session_start="$ADAPTER_ROOT/bin/afk-session-start"
# A source checkout keeps adapters/ and bin/ as siblings. Installed runtimes
# put both below afk-runtime/, which is the path persisted in real hooks.
if [[ ! -e "$session_start" && -x "$ADAPTER_ROOT/../bin/afk-session-start" ]]; then
  session_start="$(cd "$ADAPTER_ROOT/.." && pwd -P)/bin/afk-session-start"
fi
session_start_timeout=120
afk_auto_update_supported() { [[ "${OSTYPE:-}" == linux* ]]; }
auto_update=false
afk_auto_update_supported && auto_update=true
updater="$session_start"
[[ "$auto_update" == true ]] || updater=""
claude_command="$ADAPTER_ROOT/claude/statusline.sh"
claude_compact="$ADAPTER_ROOT/worker-context.sh compact --harness claude"
claude_instruction="$ADAPTER_ROOT/worker-context.sh session-start --harness claude"
claude_prompt="$ADAPTER_ROOT/worker-context.sh prompt-boundary --harness claude"
codex_command="$ADAPTER_ROOT/codex/publish.sh"
codex_instruction="$ADAPTER_ROOT/worker-context.sh session-start --harness codex"
opencode_plugin="file://$ADAPTER_ROOT/opencode/plugin.js"

RECOVERED_PENDING=false
migrate_v2_record
recover_v2_migration
recover_pending_install
upgrade_legacy_updater_timeout || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
if [[ "$RECOVERED_PENDING" == true && "$ACTION" == remove ]]; then printf 'remove:%s:OK\n' "$HARNESS"; exit 0; fi

if [[ "$HARNESS" == claude ]]; then
  settings="$HOME_ROOT/.claude/settings.json"; command="$claude_command"
  compact="$claude_compact"; instruction="$claude_instruction"; prompt="$claude_prompt"
  backup="$STATE_DIR/adapters/claude-prior.json"; mkdir -p -- "$(dirname "$settings")"
  if [[ "$ACTION" == install ]]; then
    [[ ! -e "$settings" ]] || jq -e 'type=="object" and ((.hooks // {})|type)=="object" and ((.hooks.SessionStart // [])|type)=="array"' "$settings" >/dev/null 2>&1 || { printf 'adapter-manager: USER_CONFIG_UNREADABLE\n' >&2; exit 3; }
    if [[ -r "$record" ]] && [[ "$(jq -r '.command // ""' "$record")" == "$command" ]] \
      && [[ "$(jq -r '.updater // ""' "$record")" == "$updater" ]] \
      && [[ "$(jq -r '.compact // ""' "$record")" == "$compact" ]] \
      && [[ "$(jq -r '.instruction // ""' "$record")" == "$instruction" ]] \
      && [[ "$(jq -r '.prompt // ""' "$record")" == "$prompt" ]] \
      && [[ "$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)" == "$command" ]] \
      && record_identity_valid "$record" && restoration_metadata_valid "$record" \
      && jq -e --arg u "$updater" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --argjson t "$session_start_timeout" --argjson enabled "$auto_update" '
        [.hooks.SessionStart[]?.hooks[]? | select(.command==$u)] as $updaters
        | [.hooks.SessionStart[]? | select(.matcher=="compact") | .hooks[]? | select(.command==$i)] as $instructions
        | [.hooks.PreCompact[]?.hooks[]? | select(.command==$p)] as $compactors
        | [.hooks.UserPromptSubmit[]?.hooks[]? | select(.command==$b)] as $boundaries
        | ($updaters|length)==(if $enabled then 1 else 0 end) and ($instructions|length)==1 and ($compactors|length)==1 and ($boundaries|length)==1
        and (($enabled|not) or ($updaters[0].type=="command" and $updaters[0].timeout==$t and ($updaters[0]|has("async")|not)))
        and all([$instructions[0],$compactors[0],$boundaries[0]][]; .type=="command" and .timeout==3 and (has("async")|not))
        and (($enabled|not) or (([.hooks.SessionStart[]?.hooks[]?.command]|index($u)) < ([.hooks.SessionStart[]?.hooks[]?.command]|index($i))))' "$settings" >/dev/null 2>&1; then
      printf 'install:claude:OK\n'; exit 0
    fi
    [[ ! -r "$record" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    [[ "$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)" != "$command" ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    jq -e --arg u "$updater" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --argjson enabled "$auto_update" '
      any(.hooks.SessionStart[]?.hooks[]?; (($enabled and .command==$u) or .command==$i))
      or any(.hooks.PreCompact[]?.hooks[]?; .command==$p)
      or any(.hooks.UserPromptSubmit[]?.hooks[]?; .command==$b)' "$settings" >/dev/null 2>&1 \
      && { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    src="$(mktemp)"; base="$(mktemp)"; trap 'rm -f -- "$src" "$base"; release_manager_lock' EXIT
    config_present=false; [[ ! -e "$settings" ]] || config_present=true
    if [[ -e "$settings" ]]; then
      cp -- "$settings" "$base"
    else
      printf '{}\n' >"$base"
    fi
    jq --argjson cp "$config_present" '{present:has("statusLine"),value:(.statusLine // null),config_preexisting:$cp,hooks_preexisting:has("hooks"),
      hook_groups:{SessionStart:((.hooks // {})|has("SessionStart")),PreCompact:((.hooks // {})|has("PreCompact")),UserPromptSubmit:((.hooks // {})|has("UserPromptSubmit"))}}' "$base" >"$src"
    atomic_json "$src" "$backup"
    backup_digest="$(file_sha256 "$backup")" || { printf 'adapter-manager: DEPENDENCY_MISSING:sha256\n' >&2; exit 2; }
    jq -nc --arg s "$settings" --arg c "$command" --arg u "$updater" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --arg k "$backup" --arg d "$backup_digest" \
      --argjson present "$config_present" --argjson enabled "$auto_update" \
      '{schema:"afk-adapter-install/3",harness:"claude",phase:"installing",target:$s,command:$c,updater:$u,auto_update:$enabled,compact:$p,instruction:$i,prompt:$b,backup:$k,backup_sha256:$d,config_preexisting:$present}' >"$src"
    atomic_json "$src" "$record"
    tmp="${settings}.afk.$$"
    INSTALL_COMMITTED=false; INSTALL_TEMP_FILES=("$src" "$base" "$tmp"); trap rollback_install_on_exit EXIT
    jq --arg c "$command" --arg u "$updater" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --argjson t "$session_start_timeout" --argjson enabled "$auto_update" '
      (if (.statusLine|type)=="object" then .statusLine.command=$c
       else .statusLine={type:"command",command:$c,refreshInterval:5} end)
      | .hooks = (.hooks // {})
      | .hooks.SessionStart = ((.hooks.SessionStart // [])
          + (if $enabled then [{hooks:[{type:"command",command:$u,timeout:$t}]}] else [] end)
          + [{matcher:"compact",hooks:[{type:"command",command:$i,timeout:3}]}])
      | .hooks.PreCompact = ((.hooks.PreCompact // [])
          + [{hooks:[{type:"command",command:$p,timeout:3}]}])
      | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [])
        + [{hooks:[{type:"command",command:$b,timeout:3}]}])' "$base" >"$tmp"
    chmod --reference="$settings" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv -f -- "$tmp" "$settings"
    installed_status="$(jq -c '.statusLine' "$settings")"
    jq -nc --arg c "$command" --arg u "$updater" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --arg s "$settings" --arg k "$backup" --arg d "$backup_digest" \
      --argjson installed "$installed_status" --argjson present "$config_present" --argjson enabled "$auto_update" \
      '{schema:"afk-adapter-install/3",harness:"claude",phase:"active",target:$s,command:$c,updater:$u,auto_update:$enabled,compact:$p,instruction:$i,prompt:$b,backup:$k,backup_sha256:$d,config_preexisting:$present,installed_status_line:$installed}' >"$src"
    atomic_json "$src" "$record"
    INSTALL_COMMITTED=true
  else
    [[ -r "$record" && -e "$settings" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    if ! record_identity_valid "$record" || ! restoration_metadata_valid "$record"; then
      printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3
    fi
    updater="$(jq -r '.updater // ""' "$record")"
    auto_update="$(jq -r .auto_update "$record")"
    compact="$(jq -r '.compact // ""' "$record")"
    instruction="$(jq -r '.instruction // ""' "$record")"
    prompt="$(jq -r '.prompt // ""' "$record")"
    backup="$(jq -r '.backup // ""' "$record")"
    [[ -n "$compact" && -n "$instruction" && -n "$prompt" && -r "$backup" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    [[ "$auto_update" == false || -n "$updater" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    installed_status="$(jq -c '.installed_status_line // null' "$record")"
    current_status="$(jq -c '.statusLine // null' "$settings" 2>/dev/null || true)"
    [[ "$installed_status" != null && "$current_status" == "$installed_status" ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    claude_pending_safe "$settings" "$record" "$backup" true \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    tmp="${settings}.afk.$$"
    claude_strip_owned "$settings" "$tmp" "$record" "$backup"
    chmod --reference="$settings" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$settings"
    if jq -e '.config_preexisting==false' "$backup" >/dev/null 2>&1 \
      && jq -e 'keys==[]' "$settings" >/dev/null 2>&1; then
      rm -f -- "$settings"
    fi
    rm -f -- "$record" "$backup"
  fi
elif [[ "$HARNESS" == codex ]]; then
  command="$codex_command"; config="$HOME_ROOT/.codex/config.toml"; hooks="$HOME_ROOT/.codex/hooks.json"
  instruction="$codex_instruction"
  backup="$STATE_DIR/adapters/codex-prior.json"; mkdir -p -- "$(dirname "$config")"
  command -v yq >/dev/null || { printf 'adapter-manager: DEPENDENCY_MISSING:yq\n' >&2; exit 2; }
  if [[ "$ACTION" == install ]]; then
    base_config="$(mktemp)"; base_hooks="$(mktemp)"
    trap 'rm -f -- "$base_config" "$base_hooks" "${src:-}"; release_manager_lock' EXIT
    config_present=false; hooks_present=false
    if [[ -e "$config" ]]; then config_present=true; cp -- "$config" "$base_config"; else : >"$base_config"; fi
    if [[ -e "$hooks" ]]; then hooks_present=true; cp -- "$hooks" "$base_hooks"; else printf '{"hooks":{}}\n' >"$base_hooks"; fi
    yq -p=toml -o=json '.' "$base_config" >/dev/null 2>&1 \
      || { printf 'adapter-manager: USER_CONFIG_UNREADABLE\n' >&2; exit 3; }
    jq -e 'type=="object" and ((.hooks // {})|type)=="object"' "$base_hooks" >/dev/null 2>&1 \
      || { printf 'adapter-manager: USER_CONFIG_UNREADABLE\n' >&2; exit 3; }
    if [[ -r "$record" ]]; then
      [[ -e "$config" && -e "$hooks" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
      current_status="$(yq -p=toml -o=json '.tui.status_line // null' "$config" | jq -c .)"
      recorded_status="$(jq -c '.installed // null' "$record")"
      if [[ "$current_status" == "$recorded_status" ]] && [[ "$(jq -r '.updater // ""' "$record")" == "$updater" ]] \
        && [[ "$(jq -r '.instruction // ""' "$record")" == "$instruction" ]] \
        && record_identity_valid "$record" && restoration_metadata_valid "$record" \
        && codex_hooks_safe "$hooks" "$record" true; then
        printf 'install:codex:OK\n'; exit 0
      fi
      printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3
    fi
    jq -e --arg c "$command" --arg u "$updater" --arg i "$instruction" --argjson enabled "$auto_update" '
      any(.hooks.SessionStart[]?.hooks[]?; .command==$c or ($enabled and .command==$u) or .command==$i)
      or any(.hooks.PreCompact[]?.hooks[]?; .command==$c)' "$base_hooks" >/dev/null 2>&1 \
      && { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    hook_groups="$(jq -c '{SessionStart:((.hooks // {})|has("SessionStart")),PreCompact:((.hooks // {})|has("PreCompact"))}' "$base_hooks")"
    src="$(mktemp)"
    yq -p=toml -o=json '{"present":(.tui | has("status_line")),"value":(.tui.status_line // null)}' "$base_config" \
      | jq --argjson cp "$config_present" --argjson hp "$hooks_present" --argjson hg "$hook_groups" \
        '. + {config_preexisting:$cp,hooks_preexisting:$hp,hook_groups:$hg}' >"$src"
    atomic_json "$src" "$backup"
    backup_digest="$(file_sha256 "$backup")" || { printf 'adapter-manager: DEPENDENCY_MISSING:sha256\n' >&2; exit 2; }
    installed_expected="$(yq -p=toml -o=json '.tui.status_line = (((.tui.status_line // []) + ["model-with-reasoning","context-used","context-remaining","five-hour-limit","weekly-limit","git-branch","task-progress"]) | unique) | .tui.status_line' "$base_config")"
    jq -nc --arg c "$command" --arg u "$updater" --arg x "$instruction" --arg s "$config" --arg b "$backup" --arg h "$hooks" \
      --arg d "$backup_digest" --argjson cp "$config_present" --argjson hp "$hooks_present" --argjson hg "$hook_groups" --argjson i "$installed_expected" --argjson enabled "$auto_update" \
      '{schema:"afk-adapter-install/3",harness:"codex",phase:"installing",target:$s,command:$c,updater:$u,auto_update:$enabled,instruction:$x,backup:$b,backup_sha256:$d,hooks:$h,config_preexisting:$cp,hooks_preexisting:$hp,hook_groups:$hg,installed:$i}' >"$src"
    atomic_json "$src" "$record"
    config_tmp="${config}.afk.$$"
    INSTALL_COMMITTED=false; INSTALL_TEMP_FILES=("$src" "$base_config" "$base_hooks" "$config_tmp" "${hooks}.afk.$$"); trap rollback_install_on_exit EXIT
    cp -- "$base_config" "$config_tmp"
    yq -i -p=toml -o=toml '.tui.status_line = (((.tui.status_line // []) + ["model-with-reasoning","context-used","context-remaining","five-hour-limit","weekly-limit","git-branch","task-progress"]) | unique)' "$config_tmp"
    tmp="${hooks}.afk.$$"
    jq --arg c "$command" --arg u "$updater" --arg i "$instruction" --argjson ut "$session_start_timeout" --argjson enabled "$auto_update" '
      .hooks.SessionStart = ((.hooks.SessionStart // [])
        + (if $enabled then [{hooks:[{type:"command",command:$u,timeout:$ut}]}] else [] end)
        + [{hooks:[{type:"command",command:$c,timeout:3}]},
           {matcher:"compact",hooks:[{type:"command",command:$i,timeout:3}]}])
      | .hooks.PreCompact = ((.hooks.PreCompact // [])
        | if any(.[]?.hooks[]?; .command==$c) then .
          else . + [{hooks:[{type:"command",command:$c,timeout:3}]}] end)' "$base_hooks" >"$tmp"
    chmod --reference="$hooks" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    chmod --reference="$config" "$config_tmp" 2>/dev/null || chmod 600 "$config_tmp"
    mv -f -- "$config_tmp" "$config"; mv -f -- "$tmp" "$hooks"
    installed="$(yq -p=toml -o=json '.tui.status_line' "$config")"
    jq -nc --arg c "$command" --arg u "$updater" --arg x "$instruction" --arg s "$config" --arg b "$backup" --arg d "$backup_digest" --arg h "$hooks" \
      --argjson hp "$hooks_present" --argjson cp "$config_present" --argjson hg "$hook_groups" --argjson i "$installed" --argjson enabled "$auto_update" \
      '{schema:"afk-adapter-install/3",harness:"codex",phase:"active",target:$s,command:$c,updater:$u,auto_update:$enabled,instruction:$x,backup:$b,backup_sha256:$d,
        hooks:$h,config_preexisting:$cp,hooks_preexisting:$hp,hook_groups:$hg,installed:$i}' >"$src"; atomic_json "$src" "$record"
    INSTALL_COMMITTED=true
  else
    [[ -r "$record" && -e "$config" && -r "$backup" && -e "$hooks" ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    if ! record_identity_valid "$record" || ! restoration_metadata_valid "$record"; then
      printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3
    fi
    current_status="$(yq -p=toml -o=json '.tui.status_line // null' "$config" | jq -c .)"
    recorded_status="$(jq -c '.installed // null' "$record")"
    [[ "$current_status" == "$recorded_status" ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    updater="$(jq -r '.updater // ""' "$record")"
    auto_update="$(jq -r .auto_update "$record")"
    instruction="$(jq -r '.instruction // ""' "$record")"
    [[ -n "$instruction" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    [[ "$auto_update" == false || -n "$updater" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    codex_hooks_safe "$hooks" "$record" true \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    prior_present="$(jq -r .present "$backup")"; prior_value="$(jq -c .value "$backup")"
    if [[ "$prior_present" == true ]]; then yq -i -p=toml -o=toml ".tui.status_line = $prior_value" "$config"
    else yq -i -p=toml -o=toml 'del(.tui.status_line) | with_entries(select(.key != "tui" or (.value | length) != 0))' "$config"; fi
    if [[ -e "$hooks" ]]; then
      tmp="${hooks}.afk.$$"
      jq --slurpfile owner "$record" --slurpfile prior "$backup" --argjson ut "$session_start_timeout" '
        ($owner[0]) as $o
        | ({hooks:[{type:"command",command:$o.updater,timeout:$ut}]}) as $updater
        | ({hooks:[{type:"command",command:$o.command,timeout:3}]}) as $publisher
        | ({matcher:"compact",hooks:[{type:"command",command:$o.instruction,timeout:3}]}) as $instruction
        | .hooks.SessionStart = [(.hooks.SessionStart // [])[]
            | select((($o.auto_update|not) or .!=$updater) and .!=$publisher and .!=$instruction)]
        | if (.hooks.SessionStart|length)==0 then
            if $prior[0].hook_groups.SessionStart then .hooks.SessionStart=[] else del(.hooks.SessionStart) end
          else . end
        | .hooks.PreCompact = [(.hooks.PreCompact // [])[] | select(.!=$publisher)]
        | if (.hooks.PreCompact|length)==0 then
            if $prior[0].hook_groups.PreCompact then .hooks.PreCompact=[] else del(.hooks.PreCompact) end
          else . end
        | if .hooks=={} and $prior[0].hooks_preexisting==false then del(.hooks) else . end' "$hooks" >"$tmp"
      chmod --reference="$hooks" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$hooks"
    fi
    if jq -e '.hooks_preexisting==false' "$backup" >/dev/null 2>&1 \
      && jq -e 'keys==[]' "$hooks" >/dev/null 2>&1; then
      rm -f -- "$hooks"
    fi
    if jq -e '.config_preexisting==false' "$backup" >/dev/null 2>&1 \
      && { [[ ! -s "$config" ]] || yq -e -p=toml -o=json '(. // {}) | length==0' "$config" >/dev/null 2>&1; }; then
      rm -f -- "$config"
    fi
    rm -f -- "$record" "$backup"
  fi
elif [[ "$HARNESS" == opencode ]]; then
  if [[ -e "$HOME_ROOT/.config/opencode/opencode.jsonc" ]]; then
    config="$HOME_ROOT/.config/opencode/opencode.jsonc"
  else
    config="$HOME_ROOT/.config/opencode/opencode.json"
  fi
  plugin="$opencode_plugin"; backup="$STATE_DIR/adapters/opencode-prior.json"
  mkdir -p -- "$(dirname "$config")"
  command -v node >/dev/null || { printf 'adapter-manager: DEPENDENCY_MISSING:node\n' >&2; exit 2; }
  if [[ "$ACTION" == install ]]; then
    base="$(mktemp)"; src="$(mktemp)"; trap 'rm -f -- "$base" "$src"; release_manager_lock' EXIT
    config_present=false
    if [[ -e "$config" ]]; then config_present=true; cp -- "$config" "$base"
    else
      # shellcheck disable=SC2016
      printf '%s\n' '{"$schema":"https://opencode.ai/config.json"}' >"$base"
    fi
    inspect="$(jsonc_plugin inspect "$base" "$plugin" 2>/dev/null)" \
      || { printf 'adapter-manager: USER_CONFIG_UNREADABLE\n' >&2; exit 3; }
    if [[ -r "$record" ]] && [[ "$(jq -r '.target // empty' "$record")" == "$config" ]] \
      && [[ "$(jq -r '.command // empty' "$record")" == "$plugin" ]] \
      && [[ "$(jq -r .owned_count <<<"$inspect")" == 1 ]] \
      && record_identity_valid "$record" && restoration_metadata_valid "$record"; then
      printf 'install:opencode:OK\n'; exit 0
    fi
    [[ ! -r "$record" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    [[ "$(jq -r .contains <<<"$inspect")" == false ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    prior_present="$(jq -r .prior_present <<<"$inspect")"
    jq -nc --argjson present "$config_present" --argjson prior "$prior_present" \
      '{config_preexisting:$present,prior_plugin_present:$prior}' >"$src"
    atomic_json "$src" "$backup"
    backup_digest="$(file_sha256 "$backup")" || { printf 'adapter-manager: DEPENDENCY_MISSING:sha256\n' >&2; exit 2; }
    jq -nc --arg s "$config" --arg p "$plugin" --arg b "$backup" --arg d "$backup_digest" --argjson present "$config_present" --argjson prior "$prior_present" \
      '{schema:"afk-adapter-install/3",harness:"opencode",phase:"installing",target:$s,command:$p,backup:$b,backup_sha256:$d,config_preexisting:$present,prior_plugin_present:$prior}' >"$src"
    atomic_json "$src" "$record"
    tmp="${config}.afk.$$"
    INSTALL_COMMITTED=false; INSTALL_TEMP_FILES=("$src" "$base" "$tmp"); trap rollback_install_on_exit EXIT
    jsonc_plugin install "$base" "$plugin" >"$tmp"
    chmod --reference="$config" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv -f -- "$tmp" "$config"
    jq -nc --arg p "$plugin" --arg s "$config" --arg b "$backup" --arg d "$backup_digest" \
      --argjson prior "$prior_present" --argjson present "$config_present" \
      '{schema:"afk-adapter-install/3",harness:"opencode",phase:"active",target:$s,command:$p,backup:$b,backup_sha256:$d,prior_plugin_present:$prior,config_preexisting:$present}' >"$src"
    atomic_json "$src" "$record"
    INSTALL_COMMITTED=true
  else
    [[ -r "$record" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    if ! record_identity_valid "$record" || ! restoration_metadata_valid "$record"; then
      printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3
    fi
    config="$(jq -r '.target // empty' "$record")"; plugin="$opencode_plugin"
    prior_present="$(jq -r '.prior_plugin_present' "$backup")"
    [[ -n "$config" && -n "$plugin" && -e "$config" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    inspect="$(jsonc_plugin inspect "$config" "$plugin" 2>/dev/null)" \
      || { printf 'adapter-manager: USER_CONFIG_UNREADABLE\n' >&2; exit 3; }
    [[ "$(jq -r .owned_count <<<"$inspect")" == 1 ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    tmp="${config}.afk.$$"; jsonc_plugin remove "$config" "$plugin" "$prior_present" >"$tmp" \
      || { rm -f -- "$tmp"; printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    chmod --reference="$config" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$config"
    inspect="$(jsonc_plugin inspect "$config" "$plugin" 2>/dev/null)" || exit 3
    [[ "$(jq -r .owned_count <<<"$inspect")" == 0 ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    if jq -e '.config_preexisting==false' "$backup" >/dev/null 2>&1 && jq -e '.keys==["$schema"]' <<<"$inspect" >/dev/null; then rm -f -- "$config"; fi
    rm -f -- "$record" "$backup"
  fi
else
  if [[ "$ACTION" == remove && -x "$ADAPTER_ROOT/orca-title.sh" ]]; then
    "$ADAPTER_ROOT/orca-title.sh" --restore --harness hermes >/dev/null 2>&1 || true
  fi
  if ! command -v hermes >/dev/null 2>&1; then printf 'HARNESS_NOT_INSTALLED:hermes\n'; exit 4; fi
  printf 'adapter-manager: HERMES_CONTRACT_NOT_QUALIFIED\n' >&2; exit 3
fi
if [[ -x "$ADAPTER_ROOT/orca-title.sh" ]]; then
  if [[ "$ACTION" == install ]]; then
    "$ADAPTER_ROOT/orca-title.sh" --enable --harness "$HARNESS" >/dev/null 2>&1 || true
  else
    "$ADAPTER_ROOT/orca-title.sh" --restore --harness "$HARNESS" >/dev/null 2>&1 || true
  fi
fi
printf '%s:%s:OK\n' "$ACTION" "$HARNESS"
