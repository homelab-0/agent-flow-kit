#!/usr/bin/env bash
# Versioned, same-user PM control evidence. This module only reads and records;
# it grants no permission to launch or adopt an autonomous session.
if [[ -n "${AFK_PM_CONTROL_SOURCED:-}" ]]; then return 0; fi
AFK_PM_CONTROL_SOURCED=1

afk_pmc_common_dir() { # <worktree path>
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

afk_pmc_normalize() { # <owner JSON> <canonical git common-dir>
  jq -ce --arg common "$2" '
    def str: type=="string" and length>0;
    def tuple: {harness,session,terminal,worktree,run_id};
    def legacy: {schema:"afk-pm-control/1",execution_profile:"unverified",
      control_owner:"unverified",approval_channel:"unverified",revision:null,
      launch_provenance:{status:"unverified"},provenance:{status:"unverified"}};
    . as $owner |
    select(($owner|type)=="object" and
      ($owner.schema|IN("afk-pm-ownership/2","afk-pm-ownership/3")) and
      $owner.owned==true and $owner.role=="PM" and
      ($owner.harness|IN("claude","codex","opencode")) and
      ($owner.session|str) and ($owner.terminal|str) and
      ($owner.worktree|type)=="object" and
      ($owner.worktree.id|str) and ($owner.worktree.path|str) and
      ($owner.run_id==null or ($owner.run_id|str))) |
    if has("control")|not then legacy
    else .control as $c |
      select(($c|type)=="object" and $c.schema=="afk-pm-control/1" and
        ($c.execution_profile|IN("unverified","interactive","autonomous")) and
        ($c.control_owner|IN("unverified","human","paperclip")) and
        ($c.approval_channel|IN("unverified","terminal_human","external_provider")) and
        ($c.revision|type)=="number" and $c.revision>=0 and $c.revision<=9007199254740991 and
        ($c.revision|floor)==$c.revision and ($c.launch_provenance|type)=="object" and
        ($c.launch_provenance.status|IN("unverified","attested")) and
        ($c.provenance|type)=="object" and
        ($c.provenance.status|IN("human_registration","successor_continuity","attested")) and
        ($common|str) and
        $c.provenance.repo_common_dir==$common and
        $c.provenance.owner==($owner|tuple) and
        (if $c.execution_profile=="unverified" then
          $c.launch_provenance=={status:"unverified"} and
          ($c.approval_channel=="unverified") and
          (($c.provenance.status=="human_registration" and $c.control_owner=="human") or
           ($c.provenance.status=="successor_continuity" and
            ($c.provenance.prior_control_owner|IN("unverified","human","paperclip")) and
            $c.control_owner==(if $c.provenance.prior_control_owner=="human" then "human" else "unverified" end)))
         else
          $c.launch_provenance.status=="attested" and
          ($c.launch_provenance.recipe_id|str) and
          ($c.launch_provenance.command_sha256|str) and
          ($c.launch_provenance.create_id|str) and
          $c.provenance.status=="attested" and
          (($c.execution_profile=="interactive" and $c.control_owner=="human" and $c.approval_channel=="terminal_human") or
           ($c.execution_profile=="autonomous" and $c.approval_channel=="external_provider" and
            ($c.control_owner|IN("human","paperclip"))))
         end)) | $c
    end' <<<"$1" 2>/dev/null
}

afk_pmc_manual() { # <owner JSON> <canonical git common-dir>
  jq -cn --argjson owner "$1" --arg common "$2" '
    {schema:"afk-pm-control/1",execution_profile:"unverified",control_owner:"human",
     approval_channel:"unverified",revision:0,launch_provenance:{status:"unverified"},
     provenance:{status:"human_registration",repo_common_dir:$common,
       owner:($owner|{harness,session,terminal,worktree,run_id})}}'
}

afk_pmc_successor() { # <old normalized control> <new owner JSON> <common-dir>
  jq -cn --argjson old "$1" --argjson owner "$2" --arg common "$3" '
    if $old.revision==null then null else
      {schema:"afk-pm-control/1",execution_profile:"unverified",
       control_owner:(if $old.control_owner=="human" then "human" else "unverified" end),
       approval_channel:"unverified",revision:$old.revision,
       launch_provenance:{status:"unverified"},
       provenance:{status:"successor_continuity",repo_common_dir:$common,
         owner:($owner|{harness,session,terminal,worktree,run_id}),
         prior_control_owner:$old.control_owner}}
    end'
}
