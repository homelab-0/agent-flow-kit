#!/usr/bin/env bash
# afk-paperclip-project.sh — `paperclip-project add|set|remove|list` and
# `paperclip-config --migrate` (AD-23 Onboarding and Migration). Edits the
# host's paperclip.json and never writes to Paperclip; `add` and `list` only
# read GET /api/projects/{id} with the host key. Reuses lib/afk-paperclip.sh,
# which must already be sourced. SOURCED, never executed.

if [[ -n "${AFK_PAPERCLIP_PROJECT_SOURCED:-}" ]]; then
  return 0
fi
AFK_PAPERCLIP_PROJECT_SOURCED=1

# afk_pcj_emit <json_mode> <result> [<detail>] -- a refusal or a result line.
afk_pcj_emit() {
  if [[ "$1" == true ]]; then
    jq -nc --arg r "$2" --arg d "${3:-}" '{result: $r} + (if $d == "" then {} else {detail: $d} end)'
  else
    printf 'agent-flow-kit paperclip-project: %s%s\n' "$2" "${3:+: $3}"
  fi
}

# afk_pcj_write <config-json> -- temp file beside the config, mode 600, rename.
afk_pcj_write() {
  local path tmp
  path="$(afk_pc_config_path)"
  tmp="$(mktemp "$path.XXXXXX")" || return 1
  if ! { chmod 600 "$tmp" && jq '.' <<<"$1" >"$tmp" && mv -f -- "$tmp" "$path"; } 2>/dev/null; then
    rm -f -- "$tmp"; return 1
  fi
}

# afk_pcj_common <repo> -- the repo's git common-dir, or the path itself.
afk_pcj_common() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '%s' "$1"
}

# afk_pcj_kit_merge_refused <repo> <merge> -- --merge pm on agent-flow-kit's own
# repo is refused (AD-25).
afk_pcj_kit_merge_refused() {
  [[ "$2" == pm ]] && afk_pc_is_kit_repo "$1"
}

# afk_pcj_ledger_check <jq-select-on-.issues[]> [<--arg name> <value>] -- prints
# "held" when a ledger issue matches, "unreadable" when the ledger file exists
# but does not parse (never read as "nothing held"), else nothing.
afk_pcj_ledger_check() {
  local ledger="$AFK_STATE_DIR/paperclip/ledger.json"
  [[ -e "$ledger" ]] || return 0
  if ! jq -e 'type == "object"' "$ledger" >/dev/null 2>&1; then printf unreadable; return 0; fi
  if jq -e "${@:2}" "any(.issues[]?; $1)" "$ledger" >/dev/null 2>&1; then printf held; fi
}

# afk_pcj_host_key -- reads the host key into AFK_PCJ_KEY; empty on failure.
afk_pcj_host_key() {
  local -; set +x
  AFK_PCJ_KEY="$("$AFK_PC_OP" read "$(jq -r '.host.key_ref' <<<"$AFK_PC_CFG")" 2>/dev/null)"
  [[ -n "$AFK_PCJ_KEY" ]]
}

# set and remove do not take the poll lock: afk_pcj_write is a temp file plus
# one atomic rename, and a pass reads the config once at its start, so it sees
# either the whole old file or the whole new one.
afk_cmd_paperclip_project() { # <json> <verb> <project-id> <slug> <repo> <harness> <max> <merge> <accept-mismatch>
  local -; set +x
  local json="$1" verb="$2" pid="${3,,}" slug="$4" repo="$5" harness="$6" max="$7" merge="$8" accept="$9"
  if ! afk_pc_load_config; then afk_pcj_emit "$json" "$AFK_PC_REFUSAL"; return 4; fi
  local cfg="$AFK_PC_CFG" row rows

  case "$verb" in
    add)
      harness="${harness:-claude}"; max="${max:-1}"; merge="${merge:-human}"
      afk_pc_uuid_ok "$pid" || { afk_pcj_emit "$json" PAPERCLIP_ID_INVALID "--project-id"; return 4; }
      afk_pc_slug_ok "$slug" && [[ "$repo" == /* ]] && [[ "$harness" =~ ^(claude|codex|opencode)$ ]] &&
        [[ "$max" =~ ^[1-9][0-9]{0,2}$ && "$merge" =~ ^(human|pm)$ ]] ||
        { afk_pcj_emit "$json" PAPERCLIP_CONFIG_INVALID "slug, absolute --repo, harness, max-active or merge"; return 4; }
      local rd common
      rd="$(afk_pc_repo_ready "$repo" "")" ||
        { afk_pcj_emit "$json" PAPERCLIP_PROJECT_REPO_NOT_READY "$rd"; return 4; }
      common="$(afk_pcj_common "$repo")"
      while IFS=$'\x1f' read -r rid rslug rrepo; do
        [[ -n "$rid" ]] || continue
        if [[ "$rid" == "$pid" || "$rslug" == "$slug" || "$(afk_pcj_common "$rrepo")" == "$common" ]]; then
          afk_pcj_emit "$json" PAPERCLIP_CONFIG_INVALID "project id, slug or repo already configured ($rslug)"; return 4
        fi
      done < <(jq -r '.projects[] | [.paperclip_project_id, .slug, .repo_path] | join("\u001f")' <<<"$cfg")
      if afk_pcj_kit_merge_refused "$repo" "$merge"; then
        afk_pcj_emit "$json" PAPERCLIP_MERGE_KIT_REPO "--merge pm is not allowed on the agent-flow-kit repo"; return 4
      fi
      local api_url resp code body
      api_url="$(jq -r '.api_url' <<<"$cfg")"
      afk_pcj_host_key || { afk_pcj_emit "$json" PAPERCLIP_VAULT_UNAVAILABLE; return 4; }
      resp="$(afk_pc_curl GET "$api_url/api/projects/$pid" "$AFK_PCJ_KEY" "")"
      code="${resp%%$'\n'*}"; body="${resp#*$'\n'}"
      if [[ "$code" != 200 ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$body"; then
        afk_pcj_emit "$json" PAPERCLIP_PROJECT_UNREADABLE "GET /api/projects/${pid:0:8} returned ${code:-no response}"; return 4
      fi
      if [[ -n "$(jq -r '.archivedAt // empty | tostring' <<<"$body")" ]]; then
        afk_pcj_emit "$json" PAPERCLIP_PROJECT_ARCHIVED; return 4
      fi
      local want have note=""
      want="$(jq -r '.codebase.repoUrl // empty | strings' <<<"$body")"
      if [[ -n "$want" ]]; then
        have="$(afk_pc_origin_normalize "$(git -C "$repo" remote get-url origin 2>/dev/null)")" ||
          { afk_pcj_emit "$json" PAPERCLIP_PROJECT_REPO_NOT_READY "ORIGIN_UNREADABLE"; return 4; }
        want="$(afk_pc_origin_normalize "$want")" || want="(unparseable repoUrl)"
        if [[ "$want" != "$have" ]]; then
          if [[ "$accept" != true ]]; then
            afk_pcj_emit "$json" PAPERCLIP_PROJECT_REPO_MISMATCH "Paperclip project repo is $want, this host's origin is $have; pass --accept-mismatch to add anyway"
            return 4
          fi
          note="the poller still self-blocks issues in this project with PAPERCLIP_PROJECT_REPO_MISMATCH (Paperclip $want, host $have) until they match"
        fi
      fi
      cfg="$(jq --arg p "$pid" --arg s "$slug" --arg r "$repo" --arg h "$harness" --argjson m "$max" --arg g "$merge" \
        '.projects = ((.projects // []) + [{paperclip_project_id: $p, slug: $s, repo_path: $r, harness: $h, max_active_issues: $m, merge: $g}])' \
        "$(afk_pc_config_path)")" && afk_pcj_write "$cfg" || { afk_pcj_emit "$json" PAPERCLIP_CONFIG_WRITE_FAILED; return 1; }
      if [[ "$json" == true ]]; then
        jq -nc --arg s "$slug" --arg p "$pid" --arg n "$note" '{result: "added", slug: $s, paperclip_project_id: $p} + (if $n == "" then {} else {warning: $n} end)'
      else
        printf 'added project %s (%s)\n' "$slug" "${pid:0:8}"
        [[ -z "$note" ]] || printf 'warning: %s\n' "$note"
      fi
      return 0 ;;

    set)
      row="$(afk_pc_project_row "$slug")"
      [[ -n "$row" ]] || { afk_pcj_emit "$json" PAPERCLIP_PROJECT_UNKNOWN "$slug"; return 4; }
      [[ -z "$harness" || "$harness" =~ ^(claude|codex|opencode)$ ]] && [[ -z "$max" || "$max" =~ ^[1-9][0-9]{0,2}$ ]] &&
        [[ -z "$merge" || "$merge" =~ ^(human|pm)$ ]] ||
        { afk_pcj_emit "$json" PAPERCLIP_CONFIG_INVALID "harness, max-active or merge"; return 4; }
      afk_pcj_kit_merge_refused "$(jq -r .repo_path <<<"$row")" "$merge" &&
        { afk_pcj_emit "$json" PAPERCLIP_MERGE_KIT_REPO "--merge pm is not allowed on the agent-flow-kit repo"; return 4; }
      cfg="$(jq --arg s "$slug" --arg h "$harness" --arg m "$max" --arg g "$merge" \
        '(.projects[] | select(.slug == $s)) |= (. + (if $h == "" then {} else {harness: $h} end)
          + (if $m == "" then {} else {max_active_issues: ($m | tonumber)} end)
          + (if $g == "" then {} else {merge: $g} end))' "$(afk_pc_config_path)")" &&
        afk_pcj_write "$cfg" || { afk_pcj_emit "$json" PAPERCLIP_CONFIG_WRITE_FAILED; return 1; }
      afk_pcj_emit "$json" updated "$slug"
      return 0 ;;

    remove)
      row="$(afk_pc_project_row "$slug")"
      [[ -n "$row" ]] || { afk_pcj_emit "$json" PAPERCLIP_PROJECT_UNKNOWN "$slug"; return 4; }
      case "$(afk_pcj_ledger_check '.slug == $s and .state != "closed"' --arg s "$slug")" in
        held) afk_pcj_emit "$json" PAPERCLIP_PROJECT_IN_USE "$slug has issues that are not closed"; return 4 ;;
        unreadable) afk_pcj_emit "$json" PAPERCLIP_PROJECT_IN_USE "the ledger is unreadable, so $slug may be in use"; return 4 ;;
      esac
      cfg="$(jq --arg s "$slug" '.projects |= map(select(.slug != $s))' "$(afk_pc_config_path)")" &&
        afk_pcj_write "$cfg" || { afk_pcj_emit "$json" PAPERCLIP_CONFIG_WRITE_FAILED; return 1; }
      afk_pcj_emit "$json" removed "$slug"
      return 0 ;;

    list)
      # Readiness is the resolution result for the project itself, through the
      # same function an issue resolves with. It reads the host key once.
      local api_url key="" host_name ledger='{}' actions='[]' id out="[]" ready
      api_url="$(jq -r '.api_url' <<<"$cfg")"; host_name="$(jq -r '.host.label' <<<"$cfg")"
      afk_pcj_host_key && key="$AFK_PCJ_KEY"
      while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        if [[ -n "$key" ]]; then
          id="$(jq -r .paperclip_project_id <<<"$row")"
          afk_pc_resolve "$(jq -nc --arg p "$id" '{projectId: $p}')" "-"
          ready="$AFK_PC_RES"
        else
          ready="PAPERCLIP_VAULT_UNAVAILABLE"
        fi
        out="$(jq -c --argjson r "$row" --arg ready "$ready" '. + [$r + {readiness: $ready}]' <<<"$out")"
      done < <(jq -c '.projects[]' <<<"$cfg")
      if [[ "$json" == true ]]; then
        jq -nc --argjson p "$out" '{result: "ok", projects: $p}'
      else
        jq -r '.[] | [.slug, .paperclip_project_id[0:8], .repo_path, .harness, (.max_active_issues | tostring), .merge, .readiness] | @tsv' <<<"$out" |
          { printf 'slug\tproject\trepo\tharness\tmax\tmerge\treadiness\n'; cat; } | column -t -s $'\t'
      fi
      return 0 ;;
  esac
  afk_pcj_emit "$json" PAPERCLIP_USAGE "unknown verb"; return 1
}

# afk_cmd_paperclip_config <json> <project-id> <slug> -- `--migrate` only.
afk_cmd_paperclip_config() {
  local json="$1" pid="${2,,}" slug="$3" path cfg n agent proj lower dropped="" ts backup new held
  path="$(afk_pc_config_path)"
  local emit; emit() { afk_pcj_emit "$json" "$@"; }
  [[ -r "$path" ]] || { emit PAPERCLIP_NOT_CONFIGURED; return 4; }
  cfg="$(jq -c '.' "$path" 2>/dev/null)" || { emit PAPERCLIP_CONFIG_INVALID; return 4; }
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$cfg" || { emit PAPERCLIP_CONFIG_INVALID; return 4; }
  if [[ "$(jq -r '.schema // empty' <<<"$cfg")" == afk-paperclip-config/2 ]]; then emit PAPERCLIP_MIGRATE_NOT_NEEDED; return 4; fi
  n="$(jq '.agents | if type == "array" then length else -1 end' <<<"$cfg")"
  (( n >= 0 )) || { emit PAPERCLIP_CONFIG_INVALID "not a v1 config"; return 4; }
  (( n == 1 )) || { emit PAPERCLIP_MIGRATE_MULTI_AGENT "$n agents; onboard the projects with paperclip-project add"; return 4; }
  agent="$(jq -c '.agents[0]' <<<"$cfg")"
  afk_pc_uuid_ok "$pid" || { emit PAPERCLIP_ID_INVALID "--project-id <uuid> is required; v1 has no project id"; return 4; }
  proj="$(jq -r '.project // empty | strings' <<<"$agent")"; lower="${proj,,}"
  [[ -n "$slug" ]] || slug="$lower"
  afk_pc_slug_ok "$slug" || { emit PAPERCLIP_CONFIG_INVALID "pass --slug: '$lower' is not a valid slug"; return 4; }
  held="$(afk_pcj_ledger_check '.state != "closed"')"
  if [[ -n "$held" ]] || [[ -n "$(find "$AFK_STATE_DIR/paperclip/notices/claimed" -type f -print -quit 2>/dev/null)" ]]; then
    emit PAPERCLIP_MIGRATE_STATE_HELD "the ledger is unreadable, or an issue is not closed, or a notice is still claimed; let the PMs finish first"; return 4
  fi
  jq -e 'has("pm_merge_allowed")' >/dev/null 2>&1 <<<"$agent" && dropped=" (dropped pm_merge_allowed; merge policy is per project now)"
  new="$(jq --arg p "$pid" --arg s "$slug" '
    .agents[0] as $a | .host_label as $label
    | del(.agents, .host_label, .pm_merge_allowed)
    | .schema = "afk-paperclip-config/2"
    | .host = {label: $label, agent_id: $a.agent_id, key_ref: $a.key_ref}
    | .projects = [{paperclip_project_id: $p, slug: $s, repo_path: $a.repo_path, harness: $a.harness,
                    max_active_issues: ($a.max_active_issues // 1), merge: "human"}]' <<<"$cfg")"
  # The loader must accept what is about to replace the file.
  local probe; probe="$(mktemp)" || { emit PAPERCLIP_CONFIG_WRITE_FAILED "probe"; return 1; }
  jq '.' <<<"$new" >"$probe" || { rm -f -- "$probe"; emit PAPERCLIP_CONFIG_WRITE_FAILED "probe"; return 1; }
  if ! ( AFK_PAPERCLIP_CONFIG="$probe" afk_pc_load_config ); then
    rm -f -- "$probe"; emit PAPERCLIP_CONFIG_INVALID "the migrated config does not load"; return 4
  fi
  rm -f -- "$probe"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; backup="$path.v1.$ts"
  ( umask 077; cp -- "$path" "$backup" && chmod 600 -- "$backup" ) || { emit PAPERCLIP_CONFIG_WRITE_FAILED "backup"; return 1; }
  afk_pcj_write "$new" || { emit PAPERCLIP_CONFIG_WRITE_FAILED; return 1; }
  if [[ "$json" == true ]]; then
    jq -nc --arg s "$slug" --arg b "$backup" --arg d "$dropped" '{result: "migrated", slug: $s, backup: $b, dropped_pm_merge_allowed: ($d != "")}'
  else
    printf 'migrated to v2: project %s; old config kept at %s%s\n' "$slug" "$backup" "$dropped"
  fi
}

# afk_cmd_paperclip_merge_policy <json> <issue> -- AD-25, read-only. `pm` or
# `human` for the project the ledger pinned the issue to. Only the host's
# projects[] row is read: never the live projectId, the repo or Paperclip.
afk_cmd_paperclip_merge_policy() {
  local json="$1" id="${2,,}" ledger="$AFK_STATE_DIR/paperclip/ledger.json" pin slug pid row merge reason
  local emit; emit() { afk_pcj_emit "$json" "$@"; }
  afk_pc_load_config || { emit "$AFK_PC_REFUSAL"; return 4; }
  afk_pc_uuid_ok "$id" || { emit PAPERCLIP_ISSUE_UNKNOWN; return 4; }
  if [[ -e "$ledger" ]] && ! jq -e 'type == "object"' "$ledger" >/dev/null 2>&1; then
    emit PAPERCLIP_LEDGER_UNREADABLE; return 4
  fi
  pin="$(jq -c --arg id "$id" '.issues[$id] // empty' "$ledger" 2>/dev/null)"
  [[ -n "$pin" ]] || { emit PAPERCLIP_ISSUE_UNKNOWN; return 4; }
  IFS=$'\x1f' read -r slug pid < <(jq -r '[(.slug // "" | strings), (.paperclip_project_id // "" | strings)]
    | map(gsub("[[:cntrl:]]"; "?")) | join("\u001f")' <<<"$pin")
  if [[ "$(jq -r '.state // ""' <<<"$pin")" == waiting_setup || -z "$slug" || -z "$pid" ]]; then
    emit PAPERCLIP_ISSUE_UNPINNED "the issue has no pinned project yet"; return 4
  fi
  row="$(jq -c --arg s "$slug" --arg p "${pid,,}" \
    'first(.projects[] | select(.slug == $s and .paperclip_project_id == $p)) // empty' <<<"$AFK_PC_CFG")"
  merge=human reason=DEFAULT
  if [[ -z "$row" ]]; then
    reason=PROJECT_NOT_CONFIGURED
  elif jq -e --arg s "$slug" 'first(.projects[] | select(.slug == $s)) | has("merge")' "$(afk_pc_config_path)" >/dev/null 2>&1; then
    merge="$(jq -r '.merge' <<<"$row")" reason=CONFIGURED
    if [[ "$merge" == pm ]] && afk_pc_is_kit_repo "$(jq -r '.repo_path' <<<"$row")"; then
      merge=human reason=PAPERCLIP_MERGE_KIT_REPO
    fi
  fi
  if [[ "$json" == true ]]; then
    jq -nc --arg i "$id" --arg s "$slug" --arg m "$merge" --arg r "$reason" '{issue: $i, slug: $s, merge: $m, reason: $r}'
  else
    printf '%s (%s, project %s)\n' "$merge" "$reason" "$slug"
  fi
}
