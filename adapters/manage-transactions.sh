#!/usr/bin/env bash
# Schema-v2 migration and interrupted-install recovery for manage.sh. The core
# helpers and runtime variables are supplied by the entrypoint before sourcing.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2317

migration_record_valid() {
  local target current_status recorded_status
  case "$HARNESS" in
    claude)
      jq -e --arg t "$HOME_ROOT/.claude/settings.json" --arg b "$STATE_DIR/adapters/claude-prior.json" \
        --arg c "$claude_command" --arg u "$session_start" --arg p "$claude_compact" \
        --arg i "$claude_instruction" --arg q "$claude_prompt" \
        --arg x "$STATE_DIR/adapters/.v2-migration-claude-" '
        def clean: type=="string" and (explode|all(. >= 32 and . != 127));
        (keys|sort)==["auto_update","backup","backup_sha256","command","compact","config_preexisting","harness","installed_status_line","instruction","migration","phase","prompt","schema","target","updater"]
        and .schema=="afk-adapter-install/3" and .harness=="claude" and .phase=="migrating-v2"
        and .target==$t and .backup==$b and .command==$c and (.auto_update|type)=="boolean"
        and .updater==(if .auto_update then $u else "" end)
        and .compact==$p and .instruction==$i and .prompt==$q
        and (.config_preexisting|type)=="boolean" and (.installed_status_line|type)=="object"
        and (.migration|keys|sort)==["canonical","legacy","live","schema","stage"]
        and .migration.schema=="afk-adapter-migration/1"
        and (.migration.stage=="replace" or .migration.stage=="cleanup")
        and (.migration.live|keys|sort)==["cleanup","guard","new_sha256","old_sha256","path","tombstone"]
        and .migration.live.path==$t
        and (.migration.live.guard|clean) and (.migration.live.cleanup|clean) and (.migration.live.tombstone|clean)
        and .migration.live.guard==(.migration.live.path+".afk-v2-guard."+.migration.live.old_sha256)
        and .migration.live.cleanup==(.migration.live.guard+".cleanup")
        and .migration.live.tombstone==($x+.migration.live.old_sha256+".tombstone")
        and (.migration.live.old_sha256|type)=="string" and (.migration.live.old_sha256|test("^[0-9a-f]{64}$"))
        and (.migration.live.new_sha256|type)=="string" and (.migration.live.new_sha256|test("^[0-9a-f]{64}$"))
        and (.migration.canonical|keys|sort)==["command","compact","instruction","prompt","updater"]
        and .migration.canonical=={command:$c,updater:.updater,compact:$p,instruction:$i,prompt:$q}
        and (.migration.legacy|keys|sort)==["command","compact","instruction","prompt","updater"]
        and all([.migration.legacy.command,.migration.legacy.updater,.migration.legacy.compact,
                 .migration.legacy.instruction,.migration.legacy.prompt][]; clean)' "$record" >/dev/null 2>&1 || return 1
      ;;
    codex)
      jq -e --arg t "$HOME_ROOT/.codex/config.toml" --arg h "$HOME_ROOT/.codex/hooks.json" \
        --arg b "$STATE_DIR/adapters/codex-prior.json" --arg c "$codex_command" \
        --arg u "$session_start" --arg i "$codex_instruction" \
        --arg x "$STATE_DIR/adapters/.v2-migration-codex-" '
        def clean: type=="string" and (explode|all(. >= 32 and . != 127));
        (keys|sort)==["auto_update","backup","backup_sha256","command","config_preexisting","harness","hook_groups","hooks","hooks_preexisting","installed","instruction","migration","phase","schema","target","updater"]
        and .schema=="afk-adapter-install/3" and .harness=="codex" and .phase=="migrating-v2"
        and .target==$t and .hooks==$h and .backup==$b and .command==$c and (.auto_update|type)=="boolean"
        and .updater==(if .auto_update then $u else "" end) and .instruction==$i
        and .config_preexisting==true and (.hooks_preexisting|type)=="boolean"
        and (.hook_groups|keys|sort)==["PreCompact","SessionStart"] and all(.hook_groups[]; type=="boolean")
        and (.installed|type)=="array" and all(.installed[]; type=="string")
        and (.migration|keys|sort)==["canonical","legacy","live","schema","stage"]
        and .migration.schema=="afk-adapter-migration/1"
        and (.migration.stage=="replace" or .migration.stage=="cleanup")
        and (.migration.live|keys|sort)==["cleanup","guard","new_sha256","old_sha256","path","tombstone"] and .migration.live.path==$h
        and (.migration.live.guard|clean) and (.migration.live.cleanup|clean) and (.migration.live.tombstone|clean)
        and .migration.live.guard==(.migration.live.path+".afk-v2-guard."+.migration.live.old_sha256)
        and .migration.live.cleanup==(.migration.live.guard+".cleanup")
        and .migration.live.tombstone==($x+.migration.live.old_sha256+".tombstone")
        and (.migration.live.old_sha256|type)=="string" and (.migration.live.old_sha256|test("^[0-9a-f]{64}$"))
        and (.migration.live.new_sha256|type)=="string" and (.migration.live.new_sha256|test("^[0-9a-f]{64}$"))
        and (.migration.canonical|keys|sort)==["command","instruction","updater"]
        and .migration.canonical=={command:$c,updater:.updater,instruction:$i}
        and (.migration.legacy|keys|sort)==["command","instruction","updater"]
        and all([.migration.legacy.command,.migration.legacy.updater,.migration.legacy.instruction][]; clean)' "$record" >/dev/null 2>&1 || return 1
      target="$HOME_ROOT/.codex/config.toml"; safe_exact_path "$target" "$target" || return 1
      current_status="$(yq -p=toml -o=json '.tui.status_line // null' "$target" 2>/dev/null | jq -c .)" || return 1
      recorded_status="$(jq -c .installed "$record")" || return 1
      [[ "$current_status" == "$recorded_status" ]] || return 1 ;;
    opencode)
      jq -e --arg j "$HOME_ROOT/.config/opencode/opencode.json" --arg jc "$HOME_ROOT/.config/opencode/opencode.jsonc" \
        --arg b "$STATE_DIR/adapters/opencode-prior.json" --arg p "$opencode_plugin" \
        --arg x "$STATE_DIR/adapters/.v2-migration-opencode-" '
        def clean: type=="string" and (explode|all(. >= 32 and . != 127));
        (keys|sort)==["backup","backup_sha256","command","config_preexisting","harness","migration","phase","prior_plugin_present","schema","target"]
        and .schema=="afk-adapter-install/3" and .harness=="opencode" and .phase=="migrating-v2"
        and (.target==$j or .target==$jc) and .backup==$b and .command==$p
        and .config_preexisting==true and (.prior_plugin_present|type)=="boolean"
        and (.migration|keys|sort)==["canonical","legacy","live","schema","stage"]
        and .migration.schema=="afk-adapter-migration/1"
        and (.migration.stage=="replace" or .migration.stage=="cleanup")
        and (.migration.live|keys|sort)==["cleanup","guard","new_sha256","old_sha256","path","tombstone"] and .migration.live.path==.target
        and (.migration.live.guard|clean) and (.migration.live.cleanup|clean) and (.migration.live.tombstone|clean)
        and .migration.live.guard==(.migration.live.path+".afk-v2-guard."+.migration.live.old_sha256)
        and .migration.live.cleanup==(.migration.live.guard+".cleanup")
        and .migration.live.tombstone==($x+.migration.live.old_sha256+".tombstone")
        and (.migration.live.old_sha256|type)=="string" and (.migration.live.old_sha256|test("^[0-9a-f]{64}$"))
        and (.migration.live.new_sha256|type)=="string" and (.migration.live.new_sha256|test("^[0-9a-f]{64}$"))
        and (.migration.canonical|keys)==["command"] and .migration.canonical.command==$p
        and (.migration.legacy|keys)==["command"] and (.migration.legacy.command|clean)' "$record" >/dev/null 2>&1 || return 1
      ;;
  esac
  restoration_metadata_valid "$record"
}
render_v2_migration_live() { # source destination
  local source="$1" destination="$2" scratch old_plugin
  case "$HARNESS" in
    claude)
      jq --slurpfile owner "$record" --arg c "$claude_command" --arg u "$(jq -r .updater "$record")" \
        --argjson enabled "$(jq -r .auto_update "$record")" --argjson ut "$session_start_timeout" \
        --arg p "$claude_compact" --arg i "$claude_instruction" --arg q "$claude_prompt" '
        ($owner[0].migration.legacy) as $o
        | .statusLine.command=$c
        | .hooks.SessionStart = [(.hooks.SessionStart // [])[]
            | .hooks = [(.hooks // [])[]
                | if .command==$o.updater then (if $enabled then .command=$u | .timeout=$ut else empty end)
                  elif .command==$o.instruction then .command=$i else . end]
            | select((.hooks|length)>0)]
        | .hooks.PreCompact = [(.hooks.PreCompact // [])[]
            | .hooks = [(.hooks // [])[] | if .command==$o.compact then .command=$p else . end]]
        | .hooks.UserPromptSubmit = [(.hooks.UserPromptSubmit // [])[]
            | .hooks = [(.hooks // [])[] | if .command==$o.prompt then .command=$q else . end]]' \
        "$source" >"$destination" ;;
    codex)
      jq --slurpfile owner "$record" --arg c "$codex_command" --arg u "$(jq -r .updater "$record")" \
        --argjson enabled "$(jq -r .auto_update "$record")" --argjson ut "$session_start_timeout" --arg i "$codex_instruction" '
        ($owner[0].migration.legacy) as $o
        | .hooks.SessionStart = [(.hooks.SessionStart // [])[]
            | .hooks = [(.hooks // [])[]
                | if .command==$o.updater then (if $enabled then .command=$u | .timeout=$ut else empty end)
                  elif .command==$o.command then .command=$c
                  elif .command==$o.instruction then .command=$i else . end]
            | select((.hooks|length)>0)]
        | .hooks.PreCompact = [(.hooks.PreCompact // [])[]
            | .hooks = [(.hooks // [])[] | if .command==$o.command then .command=$c else . end]]' \
        "$source" >"$destination" ;;
    opencode)
      old_plugin="$(jq -r .migration.legacy.command "$record")"
      if [[ "$old_plugin" == "$opencode_plugin" ]]; then cp -- "$source" "$destination"; return 0; fi
      scratch="$(mktemp)" || return 1
      if ! jsonc_plugin remove "$source" "$old_plugin" >"$scratch" \
        || ! jsonc_plugin install "$scratch" "$opencode_plugin" >"$destination"; then
        rm -f -- "$scratch"; return 1
      fi
      rm -f -- "$scratch" ;;
  esac
}
recover_v2_migration() {
  local stage target guard cleanup tombstone old_identity new_identity current_identity
  local guard_identity cleanup_identity tombstone_identity tmp tmp_identity src source source_inode tombstone_inode
  local restore_inode restore_identity
  tombstone_inode=""
  [[ -r "$record" ]] || return 0
  jq -e '.schema=="afk-adapter-install/3" and .phase=="migrating-v2"' "$record" >/dev/null 2>&1 || return 0
  migration_record_valid || migration_recovery_conflict
  stage="$(jq -r .migration.stage "$record")"
  target="$(jq -r .migration.live.path "$record")"
  guard="$(jq -r .migration.live.guard "$record")"
  cleanup="$(jq -r .migration.live.cleanup "$record")"
  tombstone="$(jq -r .migration.live.tombstone "$record")"
  old_identity="$(jq -r .migration.live.old_sha256 "$record")"
  new_identity="$(jq -r .migration.live.new_sha256 "$record")"
  safe_exact_path "$target" "$target" true || migration_recovery_conflict
  safe_exact_path "$guard" "$guard" true || migration_recovery_conflict
  safe_exact_path "$cleanup" "$cleanup" true || migration_recovery_conflict
  safe_exact_path "$tombstone" "$tombstone" true || migration_recovery_conflict
  current_identity="$(regular_file_sha256 "$target" 2>/dev/null || true)"
  guard_identity="$(regular_file_sha256 "$guard" 2>/dev/null || true)"
  cleanup_identity="$(regular_file_sha256 "$cleanup" 2>/dev/null || true)"
  tombstone_identity="$(regular_file_sha256 "$tombstone" 2>/dev/null || true)"
  if [[ "$stage" == cleanup && "$current_identity" == "$new_identity" \
      && ! -e "$guard" && ! -L "$guard" && ! -e "$cleanup" && ! -L "$cleanup" \
      && ! -L "$tombstone" && -f "$tombstone" \
      && -n "$tombstone_identity" && "$tombstone_identity" != "$old_identity" ]]; then
    restore_inode="$(file_id "$tombstone" 2>/dev/null)" || migration_recovery_conflict
    restore_identity="$tombstone_identity"
    [[ ! -L "$target" && -f "$target" \
      && "$(file_sha256 "$target" 2>/dev/null)" == "$new_identity" \
      && ! -e "$guard" && ! -L "$guard" && ! -e "$cleanup" && ! -L "$cleanup" \
      && ! -L "$tombstone" && -f "$tombstone" \
      && "$(file_id "$tombstone" 2>/dev/null)" == "$restore_inode" \
      && "$(file_sha256 "$tombstone" 2>/dev/null)" == "$restore_identity" ]] \
      || migration_recovery_conflict
    mv -n -- "$tombstone" "$cleanup" || migration_recovery_conflict
    [[ ! -e "$tombstone" && ! -L "$tombstone" && ! -L "$cleanup" && -f "$cleanup" \
      && "$(file_id "$cleanup" 2>/dev/null)" == "$restore_inode" \
      && "$(file_sha256 "$cleanup" 2>/dev/null)" == "$restore_identity" ]] \
      || migration_recovery_conflict
    migration_recovery_conflict
  fi
  [[ -z "$guard_identity" || "$guard_identity" == "$old_identity" ]] || migration_recovery_conflict
  [[ -z "$cleanup_identity" || "$cleanup_identity" == "$old_identity" ]] || migration_recovery_conflict
  [[ -z "$tombstone_identity" || "$tombstone_identity" == "$old_identity" ]] || migration_recovery_conflict
  [[ -z "$guard_identity" || -z "$cleanup_identity" ]] || migration_recovery_conflict
  [[ -z "$guard_identity" || -z "$tombstone_identity" ]] || migration_recovery_conflict
  [[ -z "$cleanup_identity" || -z "$tombstone_identity" ]] || migration_recovery_conflict

  if [[ "$stage" == replace && ( -n "$cleanup_identity" || -n "$tombstone_identity" ) ]]; then
    migration_recovery_conflict
  fi
  if [[ "$stage" == replace && "$current_identity" != "$new_identity" ]]; then
    if [[ "$current_identity" == "$old_identity" && -z "$guard_identity" ]]; then
      source="$target"
    elif [[ -z "$current_identity" && "$guard_identity" == "$old_identity" ]]; then
      source="$guard"
    else
      migration_recovery_conflict
    fi
    source_inode="$(file_id "$source" 2>/dev/null)" || migration_recovery_conflict
    tmp="$(mktemp "${target}.afk-v2.XXXXXX")" || migration_recovery_conflict
    [[ "$tmp" == "${target}.afk-v2."?????? && ! -L "$tmp" && -f "$tmp" ]] || migration_recovery_conflict
    render_v2_migration_live "$source" "$tmp" || { rm -f -- "$tmp"; migration_recovery_conflict; }
    tmp_identity="$(file_sha256 "$tmp" 2>/dev/null)" || { rm -f -- "$tmp"; migration_recovery_conflict; }
    [[ "$tmp_identity" == "$new_identity" ]] || { rm -f -- "$tmp"; migration_recovery_conflict; }
    chmod --reference="$source" "$tmp" 2>/dev/null || chmod 600 "$tmp"

    if [[ "$source" == "$target" ]]; then
      [[ ! -e "$guard" && ! -L "$guard" && ! -L "$target" && -f "$target" \
        && "$(file_id "$target" 2>/dev/null)" == "$source_inode" \
        && "$(file_sha256 "$target" 2>/dev/null)" == "$old_identity" ]] \
        || { rm -f -- "$tmp"; migration_recovery_conflict; }
      mv -n -- "$target" "$guard" || { rm -f -- "$tmp"; migration_recovery_conflict; }
      guard_identity="$(regular_file_sha256 "$guard" 2>/dev/null || true)"
      if [[ -e "$target" || -L "$target" || "$guard_identity" != "$old_identity" ]]; then
        if [[ ! -e "$target" && ! -L "$target" && ( -e "$guard" || -L "$guard" ) ]]; then
          mv -n -- "$guard" "$target" || true
        fi
        rm -f -- "$tmp"
        migration_recovery_conflict
      fi
    else
      [[ ! -e "$target" && ! -L "$target" && ! -L "$guard" && -f "$guard" \
        && "$(file_id "$guard" 2>/dev/null)" == "$source_inode" \
        && "$(file_sha256 "$guard" 2>/dev/null)" == "$old_identity" ]] \
        || { rm -f -- "$tmp"; migration_recovery_conflict; }
    fi

    [[ ! -e "$target" && ! -L "$target" && ! -L "$guard" && -f "$guard" \
      && "$(file_id "$guard" 2>/dev/null)" == "$source_inode" \
      && "$(file_sha256 "$guard" 2>/dev/null)" == "$old_identity" \
      && ! -L "$tmp" && -f "$tmp" && "$(file_sha256 "$tmp" 2>/dev/null)" == "$new_identity" ]] \
      || { rm -f -- "$tmp"; migration_recovery_conflict; }
    mv -n -- "$tmp" "$target" || { rm -f -- "$tmp"; migration_recovery_conflict; }
    current_identity="$(regular_file_sha256 "$target" 2>/dev/null || true)"
    if [[ "$current_identity" != "$new_identity" ]]; then
      [[ ! -e "$tmp" && ! -L "$tmp" ]] || rm -f -- "$tmp"
      migration_recovery_conflict
    fi
  fi

  current_identity="$(regular_file_sha256 "$target" 2>/dev/null || true)"
  [[ "$current_identity" == "$new_identity" ]] || migration_recovery_conflict
  if [[ "$stage" == replace ]]; then
    [[ ! -e "$cleanup" && ! -L "$cleanup" && ! -e "$tombstone" && ! -L "$tombstone" ]] \
      || migration_recovery_conflict
    guard_identity="$(regular_file_sha256 "$guard" 2>/dev/null || true)"
    if [[ "$old_identity" == "$new_identity" ]]; then
      [[ -z "$guard_identity" ]] || migration_recovery_conflict
    else
      [[ "$guard_identity" == "$old_identity" ]] || migration_recovery_conflict
    fi
    src="$(mktemp)" || migration_recovery_conflict
    jq '.migration.stage="cleanup"' "$record" >"$src" || { rm -f -- "$src"; migration_recovery_conflict; }
    atomic_json "$src" "$record"
    rm -f -- "$src"
    migration_record_valid || migration_recovery_conflict
    stage=cleanup
  fi

  guard_identity="$(regular_file_sha256 "$guard" 2>/dev/null || true)"
  cleanup_identity="$(regular_file_sha256 "$cleanup" 2>/dev/null || true)"
  tombstone_identity="$(regular_file_sha256 "$tombstone" 2>/dev/null || true)"
  if [[ "$guard_identity" == "$old_identity" && -z "$cleanup_identity" ]]; then
    source_inode="$(file_id "$guard" 2>/dev/null)" || migration_recovery_conflict
    [[ ! -e "$cleanup" && ! -L "$cleanup" && ! -L "$guard" && -f "$guard" \
      && "$(file_id "$guard" 2>/dev/null)" == "$source_inode" \
      && "$(file_sha256 "$guard" 2>/dev/null)" == "$old_identity" ]] || migration_recovery_conflict
    mv -n -- "$guard" "$cleanup" || migration_recovery_conflict
    [[ ! -e "$guard" && ! -L "$guard" && ! -L "$cleanup" && -f "$cleanup" \
      && "$(file_id "$cleanup" 2>/dev/null)" == "$source_inode" \
      && "$(file_sha256 "$cleanup" 2>/dev/null)" == "$old_identity" ]] || migration_recovery_conflict
  elif [[ -n "$guard_identity" ]]; then
    migration_recovery_conflict
  fi

  cleanup_identity="$(regular_file_sha256 "$cleanup" 2>/dev/null || true)"
  tombstone_identity="$(regular_file_sha256 "$tombstone" 2>/dev/null || true)"
  if [[ "$cleanup_identity" == "$old_identity" && -z "$tombstone_identity" ]]; then
    source_inode="$(file_id "$cleanup" 2>/dev/null)" || migration_recovery_conflict
    [[ ! -e "$tombstone" && ! -L "$tombstone" && ! -L "$cleanup" && -f "$cleanup" \
      && "$(file_id "$cleanup" 2>/dev/null)" == "$source_inode" \
      && "$(file_sha256 "$cleanup" 2>/dev/null)" == "$old_identity" ]] || migration_recovery_conflict
    mv -n -- "$cleanup" "$tombstone" || migration_recovery_conflict
    if [[ ! -e "$cleanup" && ! -L "$cleanup" && ! -L "$tombstone" && -f "$tombstone" \
      && "$(file_id "$tombstone" 2>/dev/null)" == "$source_inode" \
      && "$(file_sha256 "$tombstone" 2>/dev/null)" == "$old_identity" ]]; then
      :
    else
      restore_inode=""
      restore_identity=""
      if [[ ! -e "$cleanup" && ! -L "$cleanup" && ! -L "$tombstone" && -f "$tombstone" ]]; then
        restore_inode="$(file_id "$tombstone" 2>/dev/null)" || migration_recovery_conflict
        restore_identity="$(file_sha256 "$tombstone" 2>/dev/null)" || migration_recovery_conflict
        [[ ! -e "$cleanup" && ! -L "$cleanup" && ! -L "$tombstone" && -f "$tombstone" \
          && "$(file_id "$tombstone" 2>/dev/null)" == "$restore_inode" \
          && "$(file_sha256 "$tombstone" 2>/dev/null)" == "$restore_identity" ]] \
          || migration_recovery_conflict
        mv -n -- "$tombstone" "$cleanup" || migration_recovery_conflict
        [[ ! -e "$tombstone" && ! -L "$tombstone" && ! -L "$cleanup" && -f "$cleanup" \
          && "$(file_id "$cleanup" 2>/dev/null)" == "$restore_inode" \
          && "$(file_sha256 "$cleanup" 2>/dev/null)" == "$restore_identity" ]] \
          || migration_recovery_conflict
      fi
      migration_recovery_conflict
    fi
    tombstone_inode="$source_inode"
  elif [[ -n "$cleanup_identity" ]]; then
    migration_recovery_conflict
  fi

  if [[ -e "$tombstone" || -L "$tombstone" ]]; then
    [[ -n "$tombstone_inode" ]] || tombstone_inode="$(file_id "$tombstone" 2>/dev/null)" \
      || migration_recovery_conflict
    [[ ! -L "$tombstone" && -f "$tombstone" \
      && "$(file_id "$tombstone" 2>/dev/null)" == "$tombstone_inode" \
      && "$(file_sha256 "$tombstone" 2>/dev/null)" == "$old_identity" ]] \
      || migration_recovery_conflict
    rm -f -- "$tombstone" || migration_recovery_conflict
  fi
  [[ "$stage" == cleanup && ! -e "$guard" && ! -L "$guard" && ! -e "$cleanup" && ! -L "$cleanup" \
    && ! -e "$tombstone" && ! -L "$tombstone" \
    && ! -L "$target" && -f "$target" && "$(file_sha256 "$target" 2>/dev/null)" == "$new_identity" ]] \
    || migration_recovery_conflict
  src="$(mktemp)" || migration_recovery_conflict
  jq 'del(.migration) | .phase="active"' "$record" >"$src" || { rm -f -- "$src"; migration_recovery_conflict; }
  atomic_json "$src" "$record"
  rm -f -- "$src"
  if ! record_identity_valid "$record" || ! restoration_metadata_valid "$record"; then migration_recovery_conflict; fi
}
migrate_v2_record() {
  local target backup hooks guard cleanup tombstone src tmp digest config_preexisting installed old_identity new_identity old_plugin
  [[ -r "$record" ]] || return 0
  jq -e '.schema=="afk-adapter-install/2"' "$record" >/dev/null 2>&1 || return 0
  v2_record_identity_valid "$record" || migration_conflict
  src="$(mktemp)" || migration_conflict
  case "$HARNESS" in
    claude)
      target="$HOME_ROOT/.claude/settings.json"; backup="$STATE_DIR/adapters/claude-prior.json"
      if ! safe_exact_path "$target" "$HOME_ROOT/.claude/settings.json" \
        || ! safe_exact_path "$backup" "$STATE_DIR/adapters/claude-prior.json"; then migration_conflict; fi
      if jq -e '
          (keys|sort)==["hook_groups","hooks_preexisting","present","value"]
          and (.present|type)=="boolean" and (.hooks_preexisting|type)=="boolean"
          and (.hook_groups|keys|sort)==["PreCompact","SessionStart","UserPromptSubmit"]
          and all(.hook_groups[]; type=="boolean")
          and (if .present==false then .value==null else true end)
          and (if .hooks_preexisting==false then all(.hook_groups[]; .==false) else true end)' "$backup" >/dev/null 2>&1; then
        config_preexisting=true
      elif jq -e '(keys|sort)==["hooks_preexisting","present","value"]
          and .present==false and .value==null and .hooks_preexisting==false' "$backup" >/dev/null 2>&1; then
        config_preexisting=false
      elif jq -e '
          (keys|sort)==["config_preexisting","hook_groups","hooks_preexisting","present","value"]
          and (.config_preexisting|type)=="boolean" and (.present|type)=="boolean"
          and (.hooks_preexisting|type)=="boolean"
          and (.hook_groups|keys|sort)==["PreCompact","SessionStart","UserPromptSubmit"]
          and all(.hook_groups[]; type=="boolean")
          and (if .present==false then .value==null else true end)
          and (if .hooks_preexisting==false then all(.hook_groups[]; .==false) else true end)
          and (if .config_preexisting==false then
            .present==false and .value==null and .hooks_preexisting==false and all(.hook_groups[]; .==false)
          else true end)' "$backup" >/dev/null 2>&1; then
        config_preexisting="$(jq -r .config_preexisting "$backup")"
      else migration_conflict; fi
      jq -e --slurpfile owner "$record" --slurpfile prior "$backup" '
        ($owner[0]) as $o
        | (if $prior[0].present and ($prior[0].value|type)=="object"
           then ($prior[0].value | .command=$o.command)
           else {type:"command",command:$o.command,refreshInterval:5} end) as $installed
        | type=="object" and .statusLine==$installed' "$target" >/dev/null 2>&1 || migration_conflict
      claude_pending_safe "$target" "$record" "$backup" true || migration_conflict
      jq --argjson cp "$config_preexisting" '
        .config_preexisting=$cp
        | .hook_groups=(.hook_groups // {SessionStart:false,PreCompact:false,UserPromptSubmit:false})' "$backup" >"$src" \
        || migration_conflict
      atomic_json "$src" "$backup"; digest="$(file_sha256 "$backup")" || migration_conflict
      tmp="$(mktemp "${target}.afk-v2.XXXXXX")" || migration_conflict
      jq --slurpfile owner "$record" --arg c "$claude_command" --arg u "$updater" --argjson enabled "$auto_update" \
        --argjson ut "$session_start_timeout" --arg p "$claude_compact" --arg i "$claude_instruction" --arg q "$claude_prompt" '
        ($owner[0]) as $o | .statusLine.command=$c
        | .hooks.SessionStart=[(.hooks.SessionStart//[])[]
            | .hooks=[(.hooks//[])[] | if .command==$o.updater then (if $enabled then .command=$u | .timeout=$ut else empty end) elif .command==$o.instruction then .command=$i else . end]
            | select((.hooks|length)>0)]
        | .hooks.PreCompact=[(.hooks.PreCompact//[])[] | .hooks=[(.hooks//[])[] | if .command==$o.compact then .command=$p else . end]]
        | .hooks.UserPromptSubmit=[(.hooks.UserPromptSubmit//[])[] | .hooks=[(.hooks//[])[] | if .command==$o.prompt then .command=$q else . end]]' "$target" >"$tmp" || migration_conflict
      old_identity="$(file_sha256 "$target")"; new_identity="$(file_sha256 "$tmp")"; installed="$(jq -c .statusLine "$tmp")"
      guard="${target}.afk-v2-guard.${old_identity}"
      cleanup="${guard}.cleanup"
      tombstone="$STATE_DIR/adapters/.v2-migration-claude-${old_identity}.tombstone"
      [[ ! -e "$guard" && ! -L "$guard" && ! -e "$cleanup" && ! -L "$cleanup" \
        && ! -e "$tombstone" && ! -L "$tombstone" ]] || migration_conflict
      jq -n --slurpfile old "$record" --arg t "$target" --arg b "$backup" --arg c "$claude_command" --arg u "$updater" \
        --arg p "$claude_compact" --arg i "$claude_instruction" --arg q "$claude_prompt" \
        --arg d "$digest" --arg oi "$old_identity" --arg ni "$new_identity" --arg g "$guard" --arg x "$cleanup" \
        --arg z "$tombstone" \
        --argjson cp "$config_preexisting" --argjson installed "$installed" --argjson enabled "$auto_update" '
        {schema:"afk-adapter-install/3",harness:"claude",phase:"migrating-v2",target:$t,backup:$b,
         command:$c,updater:$u,auto_update:$enabled,compact:$p,instruction:$i,prompt:$q,backup_sha256:$d,
         config_preexisting:$cp,installed_status_line:$installed,
         migration:{schema:"afk-adapter-migration/1",stage:"replace",
           live:{path:$t,guard:$g,cleanup:$x,tombstone:$z,old_sha256:$oi,new_sha256:$ni},
           canonical:{command:$c,updater:$u,compact:$p,instruction:$i,prompt:$q},
           legacy:{command:$old[0].command,updater:$old[0].updater,compact:$old[0].compact,
                   instruction:$old[0].instruction,prompt:$old[0].prompt}}}' >"$src" || migration_conflict
      rm -f -- "$tmp" ;;
    codex)
      target="$HOME_ROOT/.codex/config.toml"; hooks="$HOME_ROOT/.codex/hooks.json"; backup="$STATE_DIR/adapters/codex-prior.json"
      if ! safe_exact_path "$target" "$HOME_ROOT/.codex/config.toml" \
        || ! safe_exact_path "$hooks" "$HOME_ROOT/.codex/hooks.json" \
        || ! safe_exact_path "$backup" "$STATE_DIR/adapters/codex-prior.json"; then migration_conflict; fi
      jq -e --slurpfile owner "$record" '
        (((keys|sort)==["present","value"]) or
         ((keys|sort)==["config_preexisting","hook_groups","hooks_preexisting","present","value"]
          and .config_preexisting==true
          and (.hooks_preexisting|type)=="boolean"
          and (.hook_groups|keys|sort)==["PreCompact","SessionStart"]
          and all(.hook_groups[]; type=="boolean")
          and (if .hooks_preexisting==false then all(.hook_groups[]; .==false) else true end)
          and .hooks_preexisting==$owner[0].hooks_preexisting
          and .hook_groups==$owner[0].hook_groups))
        and (.present|type)=="boolean"
        and (if .present then (.value|type)=="array" and all(.value[]; type=="string") else .value==null end)' \
        "$backup" >/dev/null 2>&1 || migration_conflict
      [[ "$(yq -p=toml -o=json '.tui.status_line // null' "$target" 2>/dev/null | jq -c .)" \
        == "$(jq -c .installed "$record")" ]] || migration_conflict
      codex_hooks_safe "$hooks" "$record" true || migration_conflict
      jq --slurpfile owner "$record" '
        {present:.present,value:.value,config_preexisting:true,
         hooks_preexisting:$owner[0].hooks_preexisting,hook_groups:$owner[0].hook_groups}' "$backup" >"$src" \
        || migration_conflict
      atomic_json "$src" "$backup"; digest="$(file_sha256 "$backup")" || migration_conflict
      tmp="$(mktemp "${hooks}.afk-v2.XXXXXX")" || migration_conflict
      jq --slurpfile owner "$record" --arg c "$codex_command" --arg u "$updater" --argjson enabled "$auto_update" --argjson ut "$session_start_timeout" --arg i "$codex_instruction" '
        ($owner[0]) as $o
        | .hooks.SessionStart=[(.hooks.SessionStart//[])[]
            | .hooks=[(.hooks//[])[] | if .command==$o.updater then (if $enabled then .command=$u | .timeout=$ut else empty end) elif .command==$o.command then .command=$c elif .command==$o.instruction then .command=$i else . end]
            | select((.hooks|length)>0)]
        | .hooks.PreCompact=[(.hooks.PreCompact//[])[] | .hooks=[(.hooks//[])[] | if .command==$o.command then .command=$c else . end]]' "$hooks" >"$tmp" || migration_conflict
      old_identity="$(file_sha256 "$hooks")"; new_identity="$(file_sha256 "$tmp")"; rm -f -- "$tmp"
      guard="${hooks}.afk-v2-guard.${old_identity}"
      cleanup="${guard}.cleanup"
      tombstone="$STATE_DIR/adapters/.v2-migration-codex-${old_identity}.tombstone"
      [[ ! -e "$guard" && ! -L "$guard" && ! -e "$cleanup" && ! -L "$cleanup" \
        && ! -e "$tombstone" && ! -L "$tombstone" ]] || migration_conflict
      jq -n --slurpfile old "$record" --arg t "$target" --arg h "$hooks" --arg b "$backup" --arg c "$codex_command" \
        --arg u "$updater" --arg i "$codex_instruction" --arg d "$digest" --arg oi "$old_identity" --arg ni "$new_identity" \
        --arg g "$guard" --arg x "$cleanup" --arg z "$tombstone" --argjson enabled "$auto_update" '
        {schema:"afk-adapter-install/3",harness:"codex",phase:"migrating-v2",target:$t,hooks:$h,backup:$b,
         command:$c,updater:$u,auto_update:$enabled,instruction:$i,backup_sha256:$d,config_preexisting:true,
         hooks_preexisting:$old[0].hooks_preexisting,hook_groups:$old[0].hook_groups,installed:$old[0].installed,
         migration:{schema:"afk-adapter-migration/1",stage:"replace",
           live:{path:$h,guard:$g,cleanup:$x,tombstone:$z,old_sha256:$oi,new_sha256:$ni},
           canonical:{command:$c,updater:$u,instruction:$i},
           legacy:{command:$old[0].command,updater:$old[0].updater,instruction:$old[0].instruction}}}' >"$src" || migration_conflict ;;
    opencode)
      target="$(jq -r .target "$record")"; backup="$STATE_DIR/adapters/opencode-prior.json"
      if legacy_v2_path_matches "$target" "$HOME_ROOT/.config/opencode/opencode.json"; then
        target="$HOME_ROOT/.config/opencode/opencode.json"
      elif legacy_v2_path_matches "$target" "$HOME_ROOT/.config/opencode/opencode.jsonc"; then
        target="$HOME_ROOT/.config/opencode/opencode.jsonc"
      else migration_conflict; fi
      safe_exact_path "$target" "$target" || migration_conflict
      old_plugin="$(jq -r .command "$record")"
      if [[ -e "$backup" || -L "$backup" ]]; then
        safe_exact_path "$backup" "$STATE_DIR/adapters/opencode-prior.json" || migration_conflict
        jq -e --slurpfile owner "$record" '
          (keys|sort)==["config_preexisting","prior_plugin_present"]
          and .config_preexisting==true and .prior_plugin_present==$owner[0].prior_plugin_present' \
          "$backup" >/dev/null 2>&1 || migration_conflict
      else
        jq --slurpfile owner "$record" '{config_preexisting:true,prior_plugin_present:$owner[0].prior_plugin_present}' \
          "$record" >"$src" || migration_conflict
        atomic_json "$src" "$backup"
      fi
      [[ "$(jsonc_plugin inspect "$target" "$old_plugin" 2>/dev/null | jq -r .owned_count)" == 1 ]] || migration_conflict
      digest="$(file_sha256 "$backup")" || migration_conflict
      tmp="$(mktemp "${target}.afk-v2.XXXXXX")" || migration_conflict
      if [[ "$old_plugin" == "$opencode_plugin" ]]; then
        cp -- "$target" "$tmp" || migration_conflict
      else
        jsonc_plugin remove "$target" "$old_plugin" >"$src" || migration_conflict
        jsonc_plugin install "$src" "$opencode_plugin" >"$tmp" || migration_conflict
      fi
      old_identity="$(file_sha256 "$target")"; new_identity="$(file_sha256 "$tmp")"; rm -f -- "$tmp"
      guard="${target}.afk-v2-guard.${old_identity}"
      cleanup="${guard}.cleanup"
      tombstone="$STATE_DIR/adapters/.v2-migration-opencode-${old_identity}.tombstone"
      [[ ! -e "$guard" && ! -L "$guard" && ! -e "$cleanup" && ! -L "$cleanup" \
        && ! -e "$tombstone" && ! -L "$tombstone" ]] || migration_conflict
      jq -n --slurpfile old "$record" --arg t "$target" --arg b "$backup" --arg p "$opencode_plugin" \
        --arg d "$digest" --arg oi "$old_identity" --arg ni "$new_identity" --arg g "$guard" --arg x "$cleanup" \
        --arg z "$tombstone" '
        {schema:"afk-adapter-install/3",harness:"opencode",phase:"migrating-v2",target:$t,command:$p,
         backup:$b,backup_sha256:$d,prior_plugin_present:$old[0].prior_plugin_present,config_preexisting:true,
         migration:{schema:"afk-adapter-migration/1",stage:"replace",
           live:{path:$t,guard:$g,cleanup:$x,tombstone:$z,old_sha256:$oi,new_sha256:$ni},
           canonical:{command:$p},
           legacy:{command:$old[0].command}}}' >"$src" || migration_conflict ;;
  esac
  atomic_json "$src" "$record"
  /bin/rm -f "$src"
  migration_record_valid || migration_conflict
}
rollback_pending_install() {
  local target backup hooks tmp tmp2 plugin prior inspect tmp_inode tmp2_inode
  case "$HARNESS" in
    claude)
      target="$(jq -r '.target // empty' "$record")"; backup="$(jq -r '.backup // empty' "$record")"
      if ! safe_exact_path "$target" "$HOME_ROOT/.claude/settings.json" true \
        || ! safe_exact_path "$backup" "$STATE_DIR/adapters/claude-prior.json"; then
        printf 'adapter-manager: RECOVERY_RECORD_UNSAFE\n' >&2; exit 3
      fi
      if jq -e '.config_preexisting==true' "$backup" >/dev/null 2>&1 && [[ ! -e "$target" ]]; then
        printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3
      fi
      if [[ -e "$target" ]]; then
        claude_pending_safe "$target" "$record" "$backup" \
          || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
        recovery_tmp "$target" \
          || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
        tmp="$RECOVERY_TMP_PATH"; tmp_inode="$RECOVERY_TMP_INODE"
        if ! claude_strip_owned "$target" "$tmp" "$record" "$backup" \
          || ! verify_recovery_tmp "$tmp" "$tmp_inode" "$target"; then
          rm -f -- "$tmp"; printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3
        fi
        mv -f -- "$tmp" "$target"
        if jq -e '.config_preexisting==false' "$backup" >/dev/null 2>&1 && jq -e 'keys==[]' "$target" >/dev/null 2>&1; then rm -f -- "$target"; fi
      fi
      [[ ! -e "$target" ]] || jq -e --slurpfile o "$record" --slurpfile prior "$backup" '
        ($o[0]) as $r | (if $prior[0].present then .statusLine==$prior[0].value else has("statusLine")|not end)
        and (.statusLine.command // "")!=$r.command
        and ([.hooks.SessionStart[]?.hooks[]?.command,.hooks.PreCompact[]?.hooks[]?.command,.hooks.UserPromptSubmit[]?.hooks[]?.command]
          | all((($r.auto_update|not) or . != $r.updater) and . != $r.instruction and . != $r.compact and . != $r.prompt))' "$target" >/dev/null 2>&1 \
        || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; } ;;
    codex)
      target="$(jq -r '.target // empty' "$record")"; hooks="$(jq -r '.hooks // empty' "$record")"; backup="$(jq -r '.backup // empty' "$record")"
      if ! safe_exact_path "$target" "$HOME_ROOT/.codex/config.toml" true \
        || ! safe_exact_path "$hooks" "$HOME_ROOT/.codex/hooks.json" true \
        || ! safe_exact_path "$backup" "$STATE_DIR/adapters/codex-prior.json"; then
        printf 'adapter-manager: RECOVERY_RECORD_UNSAFE\n' >&2; exit 3
      fi
      if { jq -e '.config_preexisting==true' "$backup" >/dev/null 2>&1 && [[ ! -e "$target" ]]; } \
        || { jq -e '.hooks_preexisting==true' "$backup" >/dev/null 2>&1 && [[ ! -e "$hooks" ]]; }; then
        printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3
      fi
      codex_pending_safe "$target" "$hooks" "$record" "$backup" \
        || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
      if [[ -e "$target" ]]; then
        recovery_tmp "$target" \
          || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
        tmp="$RECOVERY_TMP_PATH"; tmp_inode="$RECOVERY_TMP_INODE"
        prior="$(jq -c .value "$backup")"
        if jq -e '.present' "$backup" >/dev/null; then yq -p=toml -o=toml ".tui.status_line = $prior" "$target" >"$tmp"
        else yq -p=toml -o=toml 'del(.tui.status_line) | with_entries(select(.key != "tui" or (.value|length)!=0))' "$target" >"$tmp"; fi \
          || { rm -f -- "$tmp"; printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
      fi
      if [[ -e "$hooks" ]]; then
        recovery_tmp "$hooks" \
          || { rm -f -- "${tmp:-}"; printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
        tmp2="$RECOVERY_TMP_PATH"; tmp2_inode="$RECOVERY_TMP_INODE"
        jq --slurpfile o "$record" --slurpfile prior "$backup" --argjson ut "$session_start_timeout" '
          ($o[0]) as $r
          | ({hooks:[{type:"command",command:$r.updater,timeout:$ut}]}) as $u
          | ({hooks:[{type:"command",command:$r.command,timeout:3}]}) as $p
          | ({matcher:"compact",hooks:[{type:"command",command:$r.instruction,timeout:3}]}) as $i
          | .hooks.SessionStart=[(.hooks.SessionStart//[])[]|select((($r.auto_update|not) or .!=$u) and .!=$p and .!=$i)]
          | if (.hooks.SessionStart|length)==0 then if $prior[0].hook_groups.SessionStart then .hooks.SessionStart=[] else del(.hooks.SessionStart) end else . end
          | .hooks.PreCompact=[(.hooks.PreCompact//[])[]|select(.!=$p)]
          | if (.hooks.PreCompact|length)==0 then if $prior[0].hook_groups.PreCompact then .hooks.PreCompact=[] else del(.hooks.PreCompact) end else . end
          | if (.hooks=={} and $prior[0].hooks_preexisting==false) then del(.hooks) else . end' "$hooks" >"$tmp2" \
          || { rm -f -- "${tmp:-}" "$tmp2"; printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
      fi
      if ! { [[ ! -e "$target" ]] || verify_recovery_tmp "$tmp" "$tmp_inode" "$target"; } \
        || ! { [[ ! -e "$hooks" ]] || verify_recovery_tmp "$tmp2" "$tmp2_inode" "$hooks"; }; then
        rm -f -- "${tmp:-}" "${tmp2:-}"; printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3
      fi
      [[ ! -e "$target" ]] || mv -f -- "$tmp" "$target"
      [[ ! -e "$hooks" ]] || mv -f -- "$tmp2" "$hooks"
      if jq -e '.config_preexisting==false' "$backup" >/dev/null 2>&1 && { [[ ! -s "$target" ]] || yq -e -p=toml -o=json '(.//{})|length==0' "$target" >/dev/null 2>&1; }; then rm -f -- "$target"; fi
      if jq -e '.hooks_preexisting==false' "$backup" >/dev/null 2>&1 && jq -e 'keys==[]' "$hooks" >/dev/null 2>&1; then rm -f -- "$hooks"; fi
      [[ ! -e "$target" ]] || [[ "$(yq -p=toml -o=json '.tui.status_line // null' "$target" | jq -c .)" == "$(jq -c '.value // null' "$backup")" ]] \
        || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
      [[ ! -e "$hooks" ]] || jq -e --slurpfile o "$record" '($o[0]) as $r
        | ([.hooks.SessionStart[]?.hooks[]?.command,.hooks.PreCompact[]?.hooks[]?.command]
          | all((($r.auto_update|not) or . != $r.updater) and . != $r.command and . != $r.instruction))' "$hooks" >/dev/null 2>&1 \
        || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; } ;;
    opencode)
      target="$(jq -r '.target // empty' "$record")"; plugin="$opencode_plugin"; backup="$(jq -r '.backup // empty' "$record")"
      if { ! safe_exact_path "$target" "$HOME_ROOT/.config/opencode/opencode.json" true \
        && ! safe_exact_path "$target" "$HOME_ROOT/.config/opencode/opencode.jsonc" true; } \
        || ! safe_exact_path "$backup" "$STATE_DIR/adapters/opencode-prior.json"; then
        printf 'adapter-manager: RECOVERY_RECORD_UNSAFE\n' >&2; exit 3
      fi
      if jq -e '.config_preexisting==true' "$backup" >/dev/null 2>&1 && [[ ! -e "$target" ]]; then
        printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3
      fi
      if [[ -e "$target" ]]; then
        inspect="$(jsonc_plugin inspect "$target" "$plugin" 2>/dev/null)" \
          || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
        [[ "$(jq -r .owned_count <<<"$inspect")" -le 1 ]] \
          || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
        if [[ "$(jq -r .owned_count <<<"$inspect")" == 1 ]]; then
          recovery_tmp "$target" \
            || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
          tmp="$RECOVERY_TMP_PATH"; tmp_inode="$RECOVERY_TMP_INODE"
          if ! jsonc_plugin remove "$target" "$plugin" "$(jq -r .prior_plugin_present "$backup")" >"$tmp" \
            || ! verify_recovery_tmp "$tmp" "$tmp_inode" "$target"; then
            rm -f -- "$tmp"; printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3
          fi
          mv -f -- "$tmp" "$target"
        fi
        inspect="$(jsonc_plugin inspect "$target" "$plugin" 2>/dev/null)" \
          || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
        [[ "$(jq -r .owned_count <<<"$inspect")" == 0 ]] \
          || { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
        if jq -e '.config_preexisting==false' "$backup" >/dev/null 2>&1 && jq -e '.keys==["$schema"]' <<<"$inspect" >/dev/null; then rm -f -- "$target"; fi
      fi ;;
  esac
  rm -f -- "$record"
  [[ -z "${backup:-}" ]] || rm -f -- "$backup"
  RECOVERED_PENDING=true
}
