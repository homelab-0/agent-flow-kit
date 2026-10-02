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
         prior_control_owner:$old.control_owner,prior_control:$old}}
    end'
}

# A new handoff carries the exact old owner and normalized control observed
# under the lifecycle lock. Older handoffs are readable, but unverified.
afk_pmc_handoff_state() { # <handoff JSON> <current owner JSON> <common-dir> -> verified|unverified|conflict
  local normalized
  if ! jq -e '(.state|IN("OBSERVED","CHECKPOINTED","SUCCESSOR_LAUNCHED","ACKED","OLD_CLOSED")) and
    (if .schema=="afk-pm-handoff/3" then has("expected_old") else .schema=="afk-pm-handoff/2" and (has("expected_old")|not) end)' \
    <<<"$1" >/dev/null 2>&1; then
    printf conflict; return 0
  fi
  if ! jq -e 'has("expected_old")' <<<"$1" >/dev/null 2>&1; then
    jq -r --argjson owner "$2" '
      . as $h |
      ($owner.session==$h.old.session and $owner.terminal==$h.old.terminal and
       $owner.harness==$h.old.harness and $owner.worktree==$h.old.worktree and
       $owner.run_id==$h.old.run_id and
       (if $h.old.identity==null then true else $owner.identity==$h.old.identity end)) as $old |
      ($owner.transition_id==$h.transition_id and
       $owner.previous.session==$h.old.session and
       $owner.previous.terminal==$h.old.terminal and
       (if $h.state=="SUCCESSOR_LAUNCHED" and $h.successor.session==null then true
        else $owner.session==$h.successor.session end) and
       $owner.terminal==$h.successor.terminal and
       $owner.harness==$h.successor.harness and
       $owner.worktree==$h.successor.worktree and
       $owner.run_id==$h.successor.run_id) as $new |
      if ($h.state|IN("OBSERVED","CHECKPOINTED")) then $old
      elif $h.state=="SUCCESSOR_LAUNCHED" then $old or $new
      else $new end |
      if . then "unverified" else "conflict" end' <<<"$1" 2>/dev/null || printf conflict
    return 0
  fi
  normalized="$(afk_pmc_normalize "$2" "$3")" || { printf conflict; return 0; }
  jq -r --argjson owner "$2" --argjson control "$normalized" '
    def tuple(x): x|{harness,session,terminal,worktree,run_id,identity:(.identity // null)};
    def identity(x): x|{handle,runtime_id,execution_host_id,worktree_id,tab_id,leaf_id,incarnation_id,agent_type};
    . as $h | .expected_old as $e |
    ($e.schema=="afk-pm-expected-owner/1" and
     $e.owner==tuple($h.old) and
     (if ($h.state|IN("OBSERVED","CHECKPOINTED")) then
        ($owner|{harness,session,terminal,worktree,run_id})==($e.owner|{harness,session,terminal,worktree,run_id}) and
        (if $e.owner.identity==null then true else identity($owner.identity)==identity($e.owner.identity) end) and
        $control==$e.control
      elif $h.state=="SUCCESSOR_LAUNCHED" and
        ($owner|{harness,session,terminal,worktree,run_id})==($e.owner|{harness,session,terminal,worktree,run_id}) and
        (if $e.owner.identity==null then true else identity($owner.identity)==identity($e.owner.identity) end) then
        $control==$e.control
      else
        $owner.transition_id==$h.transition_id and
        tuple($owner.previous)==$e.owner and
        ($owner|{harness,terminal,worktree,run_id})==($h.successor|{harness,terminal,worktree,run_id}) and
        (if $h.successor.session==null then true else $owner.session==$h.successor.session end) and
        (if $h.successor.identity==null then true else identity($owner.identity)==identity($h.successor.identity) end) and
        (if $h.state=="OLD_CLOSED" then true else
          $control.revision==$e.control.revision and
          $control.execution_profile=="unverified" and
          $control.launch_provenance=={status:"unverified"} and
          (if $e.control.revision==null then $control.provenance.status=="unverified"
           else $control.provenance.status=="successor_continuity" and
             $control.provenance.prior_control_owner==$e.control.control_owner and
             $control.provenance.prior_control==$e.control end) end)
      end)) |
    if . then (if $e.control.revision==null then "unverified" else "verified" end)
    else "conflict" end' <<<"$1" 2>/dev/null || printf conflict
}

# The launch receipt is meaningful only alongside the exact journaled create
# attempt and bootstrap intent. It cannot be accepted by field shape alone.
afk_pmc_launch_evidence() { # <receipt> <create> <attempt> <intent>
  jq -e -n --argjson r "$1" --argjson c "$2" --argjson a "$3" --argjson i "$4" '
    def s: type=="string" and length>0;
    $i.schema=="afk-pm-bootstrap-intent/1" and
    $c.schema=="afk-pm-launch-create/1" and
    $a==($c|.schema="afk-pm-launch-attempt/1") and
    $r.schema=="afk-pm-launch-receipt/2" and $r.accepted==true and
    ($r.terminal|s) and ($r.command_sha256|s) and ($r.create_id|s) and
    ($r.transition_id==$c.transition_id and $r.harness==$c.harness and
     $r.worktree==$c.worktree and $r.run_id==$c.run_id and
     $r.continuation_sha256==$c.continuation_sha256 and
     $r.command_sha256==$c.command_sha256 and $r.create_id==$c.create_id) and
    ($i.transition_id==$c.transition_id and $i.harness==$c.harness and
     $i.worktree==$c.worktree and $i.run_id==$c.run_id and
     $i.continuation_sha256==$c.continuation_sha256) and
    ($r.identity==null or
      ($r.identity.handle==$r.terminal and
       $r.identity.worktree_id==$r.worktree.id and
       ($r.identity.runtime_id|s)))' >/dev/null 2>&1
}
