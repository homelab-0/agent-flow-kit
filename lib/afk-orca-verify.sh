#!/usr/bin/env bash
# Static Orca contract verification (AD-30 R1, L1).

afk_orca_contract_check() {
  local contract="${AFK_ORCA_CONTRACT:-${AFK_INSTALL_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/lifecycle/orca-contract.json}"
  local registry summary class cli_code
  AFK_ORCA_VERIFY_JSON=''
  if [[ ! -r "$contract" ]] || ! jq -e '
    .schema == "afk-orca-contract/1"
    and (.commands|type)=="array" and (.commands|length)>0
    and all(.commands[];
      type=="object"
      and (.id|type)=="string" and (.id|length)>0
      and (.command|type)=="string" and (.command|length)>0
      and (.flags|type)=="array" and (.flags|length)>0
      and all(.flags[]; type=="string" and length>0))
    and (.known_defects|type)=="array" and (.known_defects|length)>0
    and all(.known_defects[]; type=="object" and (.id|type)=="string" and (.id|length)>0)
  ' "$contract" >/dev/null 2>&1; then
    AFK_ORCA_VERIFY_CLASS=INVALID_CONTRACT
    AFK_ORCA_VERIFY_JSON='{"ok":false,"class":"INVALID_CONTRACT","items":[]}'
    return 5
  fi
  if afk_orca_run --bound 15 orca-contract-registry -- agent-context --json; then
    :
  else
    cli_code="$AFK_ORCA_CODE"
    if [[ "$cli_code" == ORCA_CLI_NOT_RESOLVED ]]; then
      AFK_ORCA_VERIFY_CLASS=ORCA_CLI_NOT_RESOLVED
    else
      AFK_ORCA_VERIFY_CLASS=ORCA_CLI_UNAVAILABLE
    fi
    AFK_ORCA_VERIFY_JSON="$(jq -cn --arg class "$AFK_ORCA_VERIFY_CLASS" --arg reason "$cli_code" \
      '{ok:false,class:$class,reason_code:$reason,items:[]}')"
    return 4
  fi
  registry="$AFK_ORCA_OUT"
  if ! jq -e 'type=="object" and (.commands|type)=="array" and all(.commands[]; type=="object" and (.command|type)=="string" and (.flags|type)=="array" and all(.flags[]; type=="string"))' <<<"$registry" >/dev/null 2>&1; then
    AFK_ORCA_VERIFY_CLASS=INVALID_REGISTRY
    AFK_ORCA_VERIFY_JSON='{"ok":false,"class":"INVALID_REGISTRY","items":[]}'
    return 5
  fi
  summary="$(jq -c --slurpfile c "$contract" '
    . as $r |
    def present($registry;$cmd;$flag): any($registry.commands[]; .command==$cmd and ($flag=="" or (.flags|index($flag)!=null)));
    [$c[0].commands[] as $cmd | {id:$cmd.id,kind:"command",command:$cmd.command,flag:null},
      ($cmd.flags[] | {id:$cmd.id,kind:"flag",command:$cmd.command,flag:.})] as $requirements
    | ([$requirements[] | . + {status:(if present($r;.command; (if .kind=="flag" then .flag else "" end)) then "present" else "missing" end)}]) as $required
    | ($c[0].known_defects | map(. as $d |
       if $d.id=="defect.capabilities-command" then {id:$d.id,kind:"known_defect",command:"capabilities",flag:null,status:(if present($r;"capabilities";"") then "reappeared" else "absent" end)}
       elif $d.id=="defect.close-handle-durable" then {id:$d.id,kind:"known_defect",command:"terminal close",flag:"handle",status:(if present($r;"terminal close";"handle") or present($r;"terminal close";"durable") then "reappeared" else "absent" end)}
       else {id:$d.id,kind:"known_defect",command:null,flag:null,status:"not_evaluated_by_registry"} end)) as $defects
    | ($required + $defects) as $items
    | {missing:([$required[]|select(.status=="missing")]|length), reappeared:([$defects[]|select(.status=="reappeared")]|length), items:$items}' <<<"$registry")" || {
      AFK_ORCA_VERIFY_CLASS=INVALID_CONTRACT
      AFK_ORCA_VERIFY_JSON='{"ok":false,"class":"INVALID_CONTRACT","items":[]}'
      return 5
    }
  if ! jq -e 'has("items") and (.items|type)=="array"' <<<"$summary" >/dev/null 2>&1; then
    AFK_ORCA_VERIFY_CLASS=INVALID_REGISTRY
    AFK_ORCA_VERIFY_JSON='{"ok":false,"class":"INVALID_REGISTRY","items":[]}'
    return 5
  fi
  class=OK
  if (( $(jq -r '.reappeared' <<<"$summary") > 0 )); then class=REAPPEARED_DEFECT
  elif (( $(jq -r '.missing' <<<"$summary") > 0 )); then class=MISSING_ITEM
  fi
  AFK_ORCA_VERIFY_CLASS="$class"
  AFK_ORCA_VERIFY_JSON="$(jq -c --arg class "$class" '. + {ok:($class=="OK"),class:$class} | del(.missing,.reappeared)' <<<"$summary")"
  case "$class" in OK) return 0 ;; MISSING_ITEM) return 2 ;; REAPPEARED_DEFECT) return 3 ;; esac
}
