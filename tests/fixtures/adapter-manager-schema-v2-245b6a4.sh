#!/usr/bin/env bash
# Idempotently compose/remove AFK with native harness configuration. Every
# removal is conditional on the AFK value still being present, so later user
# edits and unrelated hooks/plugins survive.
set -euo pipefail

ACTION="${1:-}"; HARNESS="${2:-}"
shift $(( $# >= 2 ? 2 : $# ))
HOME_ROOT="${HOME:-}"
STATE_DIR="${AFK_STATE_DIR:-${XDG_STATE_HOME:-${HOME_ROOT:+$HOME_ROOT/.local/state}}/agent-flow-kit}"
ADAPTER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

record="$STATE_DIR/adapters/$HARNESS.json"
mkdir -p -- "$(dirname "$record")"; chmod 700 "$STATE_DIR" "$(dirname "$record")" 2>/dev/null || true
atomic_json() { # source target
  local source="$1" target="$2" tmp
  tmp="${target}.tmp.$$"
  jq . "$source" >"$tmp"; chmod 600 "$tmp"; mv -f -- "$tmp" "$target"
}
session_start="$ADAPTER_ROOT/bin/afk-session-start"
# A source checkout keeps adapters/ and bin/ as siblings. Installed runtimes
# put both below afk-runtime/, which is the path persisted in real hooks.
if [[ ! -e "$session_start" && -x "$ADAPTER_ROOT/../bin/afk-session-start" ]]; then
  session_start="$(cd "$ADAPTER_ROOT/.." && pwd)/bin/afk-session-start"
fi
session_start_timeout=30

if [[ "$HARNESS" == claude ]]; then
  settings="$HOME_ROOT/.claude/settings.json"; command="$ADAPTER_ROOT/claude/statusline.sh"
  compact="$ADAPTER_ROOT/worker-context.sh compact --harness claude"
  instruction="$ADAPTER_ROOT/worker-context.sh session-start --harness claude"
  prompt="$ADAPTER_ROOT/worker-context.sh prompt-boundary --harness claude"
  backup="$STATE_DIR/adapters/claude-prior.json"; mkdir -p -- "$(dirname "$settings")"
  if [[ "$ACTION" == install ]]; then
    [[ ! -e "$settings" ]] || jq -e 'type=="object" and ((.hooks // {})|type)=="object" and ((.hooks.SessionStart // [])|type)=="array"' "$settings" >/dev/null 2>&1 || { printf 'adapter-manager: USER_CONFIG_UNREADABLE\n' >&2; exit 3; }
    if [[ -r "$record" ]] && [[ "$(jq -r '.command // ""' "$record")" == "$command" ]] \
      && [[ "$(jq -r '.updater // ""' "$record")" == "$session_start" ]] \
      && [[ "$(jq -r '.compact // ""' "$record")" == "$compact" ]] \
      && [[ "$(jq -r '.instruction // ""' "$record")" == "$instruction" ]] \
      && [[ "$(jq -r '.prompt // ""' "$record")" == "$prompt" ]] \
      && [[ "$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)" == "$command" ]] \
      && jq -e --arg u "$session_start" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --argjson t "$session_start_timeout" '
        [.hooks.SessionStart[]?.hooks[]? | select(.command==$u)] as $updaters
        | [.hooks.SessionStart[]? | select(.matcher=="compact") | .hooks[]? | select(.command==$i)] as $instructions
        | [.hooks.PreCompact[]?.hooks[]? | select(.command==$p)] as $compactors
        | [.hooks.UserPromptSubmit[]?.hooks[]? | select(.command==$b)] as $boundaries
        | ($updaters|length)==1 and ($instructions|length)==1 and ($compactors|length)==1 and ($boundaries|length)==1
        and ($updaters[0].type=="command" and $updaters[0].timeout==$t and ($updaters[0]|has("async")|not))
        and all([$instructions[0],$compactors[0],$boundaries[0]][]; .type=="command" and .timeout==3 and (has("async")|not))
        and (([.hooks.SessionStart[]?.hooks[]?.command]|index($u)) < ([.hooks.SessionStart[]?.hooks[]?.command]|index($i)))' "$settings" >/dev/null 2>&1; then
      printf 'install:claude:OK\n'; exit 0
    fi
    [[ ! -r "$record" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    [[ "$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)" != "$command" ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    jq -e --arg u "$session_start" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" '
      any(.hooks.SessionStart[]?.hooks[]?; .command==$u or .command==$i)
      or any(.hooks.PreCompact[]?.hooks[]?; .command==$p)
      or any(.hooks.UserPromptSubmit[]?.hooks[]?; .command==$b)' "$settings" >/dev/null 2>&1 \
      && { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    src="$(mktemp)"; trap 'rm -f -- "$src"' EXIT
    if [[ -e "$settings" ]]; then
      jq '{present:has("statusLine"),value:(.statusLine // null),hooks_preexisting:has("hooks"),
        hook_groups:{SessionStart:((.hooks // {})|has("SessionStart")),PreCompact:((.hooks // {})|has("PreCompact")),UserPromptSubmit:((.hooks // {})|has("UserPromptSubmit"))}}' "$settings" >"$src"
    else
      printf '{"present":false,"value":null,"hooks_preexisting":false}\n' >"$src"; printf '{}\n' >"$settings"; chmod 600 "$settings"
    fi
    atomic_json "$src" "$backup"
    tmp="${settings}.afk.$$"
    jq --arg c "$command" --arg u "$session_start" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --argjson t "$session_start_timeout" '
      (if (.statusLine|type)=="object" then .statusLine.command=$c
       else .statusLine={type:"command",command:$c,refreshInterval:5} end)
      | .hooks = (.hooks // {})
      | .hooks.SessionStart = ((.hooks.SessionStart // [])
          + [{hooks:[{type:"command",command:$u,timeout:$t}]},
             {matcher:"compact",hooks:[{type:"command",command:$i,timeout:3}]}])
      | .hooks.PreCompact = ((.hooks.PreCompact // [])
          + [{hooks:[{type:"command",command:$p,timeout:3}]}])
      | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [])
          + [{hooks:[{type:"command",command:$b,timeout:3}]}])' "$settings" >"$tmp"
    chmod --reference="$settings" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$settings"
    jq -nc --arg c "$command" --arg u "$session_start" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --arg s "$settings" --arg k "$backup" \
      '{schema:"afk-adapter-install/2",harness:"claude",target:$s,command:$c,updater:$u,compact:$p,instruction:$i,prompt:$b,backup:$k}' >"$src"
    atomic_json "$src" "$record"
  else
    [[ -r "$record" && -e "$settings" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    session_start="$(jq -r '.updater // ""' "$record")"
    compact="$(jq -r '.compact // ""' "$record")"
    instruction="$(jq -r '.instruction // ""' "$record")"
    prompt="$(jq -r '.prompt // ""' "$record")"
    backup="$(jq -r '.backup // ""' "$record")"
    [[ -n "$session_start" && -n "$compact" && -n "$instruction" && -n "$prompt" && -r "$backup" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    jq -e --arg c "$command" --arg u "$session_start" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --argjson t "$session_start_timeout" '
      .statusLine.command==$c
      and ([.hooks.SessionStart[]?.hooks[]? | select(.command==$u)] | length)==1
      and ([.hooks.SessionStart[]? | select(.matcher=="compact") | .hooks[]? | select(.command==$i)] | length)==1
      and ([.hooks.PreCompact[]?.hooks[]? | select(.command==$p)] | length)==1
      and ([.hooks.UserPromptSubmit[]?.hooks[]? | select(.command==$b)] | length)==1
      and (first(.hooks.SessionStart[]?.hooks[]? | select(.command==$u))
        | .type=="command" and .timeout==$t and (has("async")|not))
      and all([first(.hooks.SessionStart[]?.hooks[]? | select(.command==$i)),
               first(.hooks.PreCompact[]?.hooks[]? | select(.command==$p)),
               first(.hooks.UserPromptSubmit[]?.hooks[]? | select(.command==$b))][];
        .type=="command" and .timeout==3 and (has("async")|not))' "$settings" >/dev/null 2>&1 \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    tmp="${settings}.afk.$$"
    jq --slurpfile prior "$backup" --arg u "$session_start" --arg p "$compact" --arg i "$instruction" --arg b "$prompt" --argjson t "$session_start_timeout" '
      (if $prior[0].present then .statusLine=$prior[0].value else del(.statusLine) end)
      | .hooks.SessionStart = [(.hooks.SessionStart // [])[]
          | .hooks = [(.hooks // [])[]
              | select((.type!="command" or .command!=$u or .timeout!=$t or has("async"))
                and (.type!="command" or .command!=$i or .timeout!=3 or has("async")))]
          | select((.hooks|length)>0)]
      | if (.hooks.SessionStart|length)==0 then
          if ($prior[0].hook_groups.SessionStart // false) then .hooks.SessionStart=[] else del(.hooks.SessionStart) end
        else . end
      | .hooks.PreCompact = [(.hooks.PreCompact // [])[]
          | .hooks = [(.hooks // [])[]
              | select(.type!="command" or .command!=$p or .timeout!=3 or has("async"))]
          | select((.hooks|length)>0)]
      | if (.hooks.PreCompact|length)==0 then
          if ($prior[0].hook_groups.PreCompact // false) then .hooks.PreCompact=[] else del(.hooks.PreCompact) end
        else . end
      | .hooks.UserPromptSubmit = [(.hooks.UserPromptSubmit // [])[]
          | .hooks = [(.hooks // [])[]
              | select(.type!="command" or .command!=$b or .timeout!=3 or has("async"))]
          | select((.hooks|length)>0)]
      | if (.hooks.UserPromptSubmit|length)==0 then
          if ($prior[0].hook_groups.UserPromptSubmit // false) then .hooks.UserPromptSubmit=[] else del(.hooks.UserPromptSubmit) end
        else . end
      | if (($prior[0].hooks_preexisting|not) and .hooks=={}) then del(.hooks) else . end' "$settings" >"$tmp"
    chmod --reference="$settings" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$settings"
    rm -f -- "$record" "$backup"
  fi
elif [[ "$HARNESS" == codex ]]; then
  command="$ADAPTER_ROOT/codex/publish.sh"; config="$HOME_ROOT/.codex/config.toml"; hooks="$HOME_ROOT/.codex/hooks.json"
  instruction="$ADAPTER_ROOT/worker-context.sh session-start --harness codex"
  backup="$STATE_DIR/adapters/codex-prior.json"; mkdir -p -- "$(dirname "$config")"
  command -v yq >/dev/null || { printf 'adapter-manager: DEPENDENCY_MISSING:yq\n' >&2; exit 2; }
  if [[ "$ACTION" == install ]]; then
    [[ -e "$config" ]] || { : >"$config"; chmod 600 "$config"; }
    hooks_present=false
    if [[ -e "$hooks" ]]; then hooks_present=true; else printf '{"hooks":{}}\n' >"$hooks"; chmod 600 "$hooks"; fi
    jq -e 'type=="object" and ((.hooks // {})|type)=="object"' "$hooks" >/dev/null 2>&1 \
      || { printf 'adapter-manager: USER_CONFIG_UNREADABLE\n' >&2; exit 3; }
    if [[ -r "$record" ]]; then
      current_status="$(yq -p=toml -o=json '.tui.status_line // null' "$config" | jq -c .)"
      recorded_status="$(jq -c '.installed // null' "$record")"
      if [[ "$current_status" == "$recorded_status" ]] && [[ "$(jq -r '.updater // ""' "$record")" == "$session_start" ]] \
        && [[ "$(jq -r '.instruction // ""' "$record")" == "$instruction" ]] \
        && jq -e --arg c "$command" --arg u "$session_start" --arg i "$instruction" --argjson ut "$session_start_timeout" '
          [.hooks.SessionStart[]?.hooks[]? | select(.command==$u)] as $updaters
          | [.hooks.SessionStart[]?.hooks[]? | select(.command==$c)] as $session_publishers
          | [.hooks.SessionStart[]? | select(.matcher=="compact") | .hooks[]? | select(.command==$i)] as $instructions
          | [.hooks.PreCompact[]?.hooks[]? | select(.command==$c)] as $compact_publishers
          | [$updaters[0],$session_publishers[0],$instructions[0],$compact_publishers[0]] as $owned
          | ($updaters|length)==1 and ($session_publishers|length)==1 and ($instructions|length)==1 and ($compact_publishers|length)==1
          and ($updaters[0].type=="command" and $updaters[0].timeout==$ut and ($updaters[0]|has("async")|not))
          and all($owned[1:][]; .type=="command" and .timeout==3 and (has("async")|not))
          and (([.hooks.SessionStart[]?.hooks[]?.command] | index($u)) < ([.hooks.SessionStart[]?.hooks[]?.command] | index($c)))
          and (([.hooks.SessionStart[]?.hooks[]?.command] | index($u)) < ([.hooks.SessionStart[]?.hooks[]?.command] | index($i)))' "$hooks" >/dev/null 2>&1; then
        printf 'install:codex:OK\n'; exit 0
      fi
      printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3
    fi
    jq -e --arg c "$command" --arg u "$session_start" --arg i "$instruction" '
      any(.hooks.SessionStart[]?.hooks[]?; .command==$c or .command==$u or .command==$i)
      or any(.hooks.PreCompact[]?.hooks[]?; .command==$c)' "$hooks" >/dev/null 2>&1 \
      && { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    src="$(mktemp)"; trap 'rm -f -- "$src"' EXIT
    yq -p=toml -o=json '{"present":(.tui | has("status_line")),"value":(.tui.status_line // null)}' "$config" >"$src"
    atomic_json "$src" "$backup"
    hook_groups="$(jq -c '{SessionStart:((.hooks // {})|has("SessionStart")),PreCompact:((.hooks // {})|has("PreCompact"))}' "$hooks")"
    yq -i -p=toml -o=toml '.tui.status_line = (((.tui.status_line // []) + ["model-with-reasoning","context-used","context-remaining","five-hour-limit","weekly-limit","git-branch","task-progress"]) | unique)' "$config"
    tmp="${hooks}.afk.$$"
    jq --arg c "$command" --arg u "$session_start" --arg i "$instruction" --argjson ut "$session_start_timeout" '
      .hooks.SessionStart = ((.hooks.SessionStart // [])
        + [{hooks:[{type:"command",command:$u,timeout:$ut}]},
           {hooks:[{type:"command",command:$c,timeout:3}]},
           {matcher:"compact",hooks:[{type:"command",command:$i,timeout:3}]}])
      | .hooks.PreCompact = ((.hooks.PreCompact // [])
        | if any(.[]?.hooks[]?; .command==$c) then .
          else . + [{hooks:[{type:"command",command:$c,timeout:3}]}] end)' "$hooks" >"$tmp"
    chmod --reference="$hooks" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$hooks"
    installed="$(yq -p=toml -o=json '.tui.status_line' "$config")"
    jq -nc --arg c "$command" --arg u "$session_start" --arg x "$instruction" --arg s "$config" --arg b "$backup" --arg h "$hooks" \
      --argjson hp "$hooks_present" --argjson hg "$hook_groups" --argjson i "$installed" \
      '{schema:"afk-adapter-install/2",harness:"codex",target:$s,command:$c,updater:$u,instruction:$x,backup:$b,
        hooks:$h,hooks_preexisting:$hp,hook_groups:$hg,installed:$i}' >"$src"; atomic_json "$src" "$record"
  else
    [[ -r "$record" && -e "$config" && -r "$backup" && -e "$hooks" ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    current_status="$(yq -p=toml -o=json '.tui.status_line // null' "$config" | jq -c .)"
    recorded_status="$(jq -c '.installed // null' "$record")"
    [[ "$current_status" == "$recorded_status" ]] \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    session_start="$(jq -r '.updater // ""' "$record")"
    instruction="$(jq -r '.instruction // ""' "$record")"
    [[ -n "$session_start" && -n "$instruction" ]] || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    jq -e --arg c "$command" --arg u "$session_start" --arg i "$instruction" --argjson ut "$session_start_timeout" '
      [.hooks.SessionStart[]?.hooks[]? | select(.command==$u)] as $updaters
      | [.hooks.SessionStart[]?.hooks[]? | select(.command==$c)] as $session_publishers
      | [.hooks.SessionStart[]? | select(.matcher=="compact") | .hooks[]? | select(.command==$i)] as $instructions
      | [.hooks.PreCompact[]?.hooks[]? | select(.command==$c)] as $compact_publishers
      | ($updaters|length)==1 and ($session_publishers|length)==1 and ($instructions|length)==1 and ($compact_publishers|length)==1
      and ($updaters[0].type=="command" and $updaters[0].timeout==$ut and ($updaters[0]|has("async")|not))
      and all([$session_publishers[0],$instructions[0],$compact_publishers[0]][]; .type=="command" and .timeout==3 and (has("async")|not))
      and (([.hooks.SessionStart[]?.hooks[]?.command] | index($u)) < ([.hooks.SessionStart[]?.hooks[]?.command] | index($c)))' "$hooks" >/dev/null 2>&1 \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    prior_present="$(jq -r .present "$backup")"; prior_value="$(jq -c .value "$backup")"
    if [[ "$prior_present" == true ]]; then yq -i -p=toml -o=toml ".tui.status_line = $prior_value" "$config"
    else yq -i -p=toml -o=toml 'del(.tui.status_line) | with_entries(select(.key != "tui" or (.value | length) != 0))' "$config"; fi
    if [[ -e "$hooks" ]]; then
      tmp="${hooks}.afk.$$"
      jq --slurpfile owner "$record" --arg c "$command" --arg u "$session_start" --arg i "$instruction" --argjson ut "$session_start_timeout" '
        .hooks.SessionStart = [(.hooks.SessionStart // [])[]
          | .hooks = [(.hooks // [])[]
              | select((.type!="command" or .command!=$u or .timeout!=$ut or has("async"))
                and (.type!="command" or .command!=$c or .timeout!=3 or has("async"))
                and (.type!="command" or .command!=$i or .timeout!=3 or has("async")))]
          | select((.hooks|length)>0)]
        | if (.hooks.SessionStart|length)==0 then
            if ($owner[0].hook_groups.SessionStart // false) then .hooks.SessionStart=[] else del(.hooks.SessionStart) end
          else . end
        | .hooks.PreCompact = [(.hooks.PreCompact // [])[]
          | .hooks = [(.hooks // [])[]
              | select(.type!="command" or .command!=$c or .timeout!=3 or has("async"))]
          | select((.hooks|length)>0)]
        | if (.hooks.PreCompact|length)==0 then
            if ($owner[0].hook_groups.PreCompact // false) then .hooks.PreCompact=[] else del(.hooks.PreCompact) end
          else . end
        | if .hooks=={} and (($owner[0].hooks_preexisting // true)|not) then del(.hooks) else . end' "$hooks" >"$tmp"
      chmod --reference="$hooks" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$hooks"
    fi
    if [[ "$(jq -r '.hooks_preexisting // true' "$record")" == false ]] && jq -e 'keys==[]' "$hooks" >/dev/null 2>&1; then
      rm -f -- "$hooks"
    fi
    rm -f -- "$record" "$backup"
  fi
elif [[ "$HARNESS" == opencode ]]; then
  if [[ -e "$HOME_ROOT/.config/opencode/opencode.jsonc" ]]; then
    config="$HOME_ROOT/.config/opencode/opencode.jsonc"
  else
    config="$HOME_ROOT/.config/opencode/opencode.json"
  fi
  plugin="file://$ADAPTER_ROOT/opencode/plugin.js"
  mkdir -p -- "$(dirname "$config")"
  if [[ ! -e "$config" ]]; then
    # shellcheck disable=SC2016
    printf '%s\n' '{"$schema":"https://opencode.ai/config.json"}' >"$config"
    chmod 600 "$config"
  fi
  jq -e 'type=="object" and ((.plugin // [])|type)=="array"' "$config" >/dev/null 2>&1 || { printf 'adapter-manager: USER_CONFIG_UNREADABLE\n' >&2; exit 3; }
  if [[ "$ACTION" == install ]]; then
    if [[ -r "$record" ]] && jq -e --arg p "$plugin" '(.plugin // [])|index($p)!=null' "$config" >/dev/null; then
      printf 'install:opencode:OK\n'; exit 0
    fi
    jq -e --arg p "$plugin" '(.plugin // [])|index($p)==null' "$config" >/dev/null \
      || { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
    prior_present="$(jq -r 'has("plugin")' "$config")"
    tmp="${config}.afk.$$"; jq --arg p "$plugin" '(.plugin // []) as $plugins
      | .plugin=(if ($plugins|index($p))!=null then $plugins else $plugins+[$p] end)' "$config" >"$tmp"
    chmod --reference="$config" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$config"
    jq -nc --arg p "$plugin" --arg s "$config" --argjson prior "$prior_present" \
      '{schema:"afk-adapter-install/2",harness:"opencode",target:$s,command:$p,prior_plugin_present:$prior}' >"${record}.tmp.$$"
    chmod 600 "${record}.tmp.$$"; mv -f -- "${record}.tmp.$$" "$record"
  else
    if [[ -e "$config" ]]; then
      prior_present="$(jq -r '.prior_plugin_present // false' "$record" 2>/dev/null)"
      tmp="${config}.afk.$$"; jq --arg p "$plugin" --argjson prior "$prior_present" \
        '.plugin=[(.plugin // [])[]|select(.!=$p)]
          | if (.plugin|length)==0 and ($prior|not) then del(.plugin) else . end' "$config" >"$tmp"
      chmod --reference="$config" "$tmp" 2>/dev/null || chmod 600 "$tmp"; mv -f -- "$tmp" "$config"
    fi
    rm -f -- "$record"
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
