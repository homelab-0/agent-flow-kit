#!/usr/bin/env bash
# Story 1.7 spike cell runner — COORDINATOR evidence tooling, not product code.
# Usage: run-cells.sh <cell-id> [<cell-id> ...]   cell-id = <profile-slug>-<mode>-<task>
#   profile slugs: lcs=local-code-standard  lg=local-general  cs=claude/strong(claude)  os=openai/strong(codex)
#   modes: full|compact|none   tasks: T1|T2|T3
# Each cell: fresh Orca worktree of the disposable target, composed story, central /v1/route,
# stamp (natural or recorded override to the cell's profile), installed dispatch.sh, independent
# gate, measurements, results/<cell>.json, cleanup. Emits one summary line per cell on stdout.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit
EV=$KIT/_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.7
RES=$EV/results; mkdir -p "$RES"
TARGET_REPO_ID=d1c607d7-063b-4e28-86ae-ae4c24038ea8
CATALOG=$HOME/.local/share/agent-flow-kit/catalogs/agent-router-1.6.0.yaml
DISPATCH=$HOME/.agents/skills/model-router/scripts/dispatch.sh
MAKESTAMP=$KIT/files/model-router/scripts/make-stamp.sh
source ~/.op-agent-env >/dev/null 2>&1
export AGENT_ROUTER_TOKEN="$(op read op://develop/caller-token/credential)"
export AGENT_STAMP_VALIDATE_CATALOG_PATH=$CATALOG AGENT_ROUTER_URL=https://agent-router.homelab0.org
export AGENT_FLOW_GATEWAY_URL=https://ai-gateway.homelab0.org AGENT_FLOW_GATEWAY_TOKEN_REF=op://develop/agw-claude-code/password
export AGENT_FLOW_OP_ENV_FILE=$HOME/.op-agent-env AGENT_FLOW_LAUNCH_TIMEOUT=${CELL_TIMEOUT:-1200}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
profile_fields() { # slug -> harness profile pool cost placement_required
  case "$1" in
    lcs) echo "claude local-code-standard null free true" ;;
    lg)  echo "claude local-general null free true" ;;
    cs)  echo "claude claude/strong anthropic-max subscription false" ;;
    os)  echo "codex openai/strong openai-plus subscription false" ;;
    *) return 1 ;;
  esac
}
run_cell() {
  local id="$1" slug mode task; slug="${id%%-*}"; task="${id##*-}"; mode="${id#*-}"; mode="${mode%-*}"
  read -r harness profile pool cost preq <<<"$(profile_fields "$slug")" || { echo "CELL $id ERROR unknown profile slug"; return; }
  local wname="cell-$id" W out="$RES/$id.json" t0; t0=$(date +%s)
  local cdir="$RES/$id"; mkdir -p "$cdir"
  local wt; wt="$(orca-ide worktree create --repo id:$TARGET_REPO_ID --name "$wname" --base-branch master --no-parent --setup skip --json 2>&1)"
  W="$(jq -r '.result.worktree.path // empty' <<<"$wt")"
  if [[ -z "$W" || ! -d "$W" ]]; then jq -n --arg id "$id" --arg err "worktree create failed" '{cell:$id,status:"error",error:$err}' > "$out"; echo "CELL $id ERROR worktree"; return; fi
  local wsel="$TARGET_REPO_ID::$W"
  # --- compose the cell story ---
  local persona_line="" persona_file="" body
  case "$mode" in full) persona_line="persona: dev-full"; persona_file="$W/_bmad/bmm/agents/dev-full.md" ;; compact) persona_line="persona: dev-compact"; persona_file="$W/_bmad/bmm/agents/dev-compact.md" ;; none) ;; esac
  body="$(cat "$W/spike/tasks/$task.md")"
  { printf -- '---\nlinear:\nstamp: CELL-%s.md.stamp.json\n' "$id"; [[ -n "$persona_line" ]] && printf '%s\n' "$persona_line"; printf 'gates:\n  - "bash spike/gates/gate-%s.sh"\nmax_cycles: 1\n---\n\n### Spike cell %s\n\nYour working directory is `%s`. Use the relative path exactly as written below; never an absolute path, never a path outside this directory, and do not probe for the repository location.\n\n%s\n' "$task" "$id" "$W" "$body"; } > "$W/stories/CELL-$id.md"
  # --- route + stamp ---
  jq -n --arg sid "CELL-$id" --arg t "Story 1.7 spike cell $id ($task, mode $mode)" --arg s "Evidence-only benchmark cell for the persona-payload viability spike: one small deterministic canary task in a disposable target, judged by a pre-declared gate. Spike-class evaluation, bounded spend, no production code." \
    '{story_id:$sid,title:$t,summary:$s,touched_paths:["spike/out/"],ambiguity:"low",blast_radius:"low",volume_hint:"high",tags:["spike"],repo:"afk-smoke-target",requester:"bmad-pm"}' > "$cdir/route-request.json"
  local http; http="$(curl -sS -m 30 -o "$cdir/route-response.json" -w '%{http_code}' -X POST "$AGENT_ROUTER_URL/v1/route" -H "Authorization: Bearer $AGENT_ROUTER_TOKEN" -H 'Content-Type: application/json' --data-binary @"$cdir/route-request.json")"
  [[ "$http" == "200" ]] || { jq -n --arg id "$id" --arg h "$http" '{cell:$id,status:"error",error:("route http "+$h)}' > "$out"; echo "CELL $id ERROR route $http"; orca-ide worktree rm --worktree "$wsel" --force --json >/dev/null 2>&1; return; }
  local nh np; nh="$(jq -r .harness "$cdir/route-response.json")"; np="$(jq -r .model_profile "$cdir/route-response.json")"
  local stamp="$cdir/CELL-$id.md.stamp.json" override="none"
  if [[ "$nh" == "$harness" && "$np" == "$profile" ]]; then
    bash "$MAKESTAMP" --response "$cdir/route-response.json" --story-id "CELL-$id" --title "Story 1.7 spike cell $id ($task, mode $mode)" --tag spike --out "$stamp" >"$cdir/make-stamp.log" 2>&1
  else
    override="$nh/$np->$harness/$profile"
    jq --arg h "$harness" --arg p "$profile" --arg pool "$pool" --arg c "$cost" --argjson pr "$preq" '. + {harness:$h, model_profile:$p, entitlement_pool:(if $pool=="null" then null else $pool end), cost_class:$c, metered:false, placement_required:$pr, rationale:("OVERRIDE-DERIVED by the coordinator for a Story 1.7 spike cell that must run on a named profile; natural decision retained as route-response.json: " + (.reason // .rationale // ""))} | del(.reason)' "$cdir/route-response.json" > "$cdir/route-response.override.json"
    bash "$MAKESTAMP" --response "$cdir/route-response.override.json" --story-id "CELL-$id" --title "Story 1.7 spike cell $id ($task, mode $mode)" --tag spike --out "$stamp" --override-harness "$harness" --override-profile "$profile" --override-actor "ORCH coordinator (Story 1.7 spike-class evaluation cell; Josh's go 2026-09-07)" --override-reason "The spike matrix requires this cell to run on $harness/$profile; the natural route returned $nh/$np. Fields derived from catalog 1.6.0; catalog_version and expires_at verbatim; bounded spend; no production code." >"$cdir/make-stamp.log" 2>&1
  fi
  [[ -s "$stamp" ]] || { jq -n --arg id "$id" '{cell:$id,status:"error",error:"stamp not written"}' > "$out"; echo "CELL $id ERROR stamp"; orca-ide worktree rm --worktree "$wsel" --force --json >/dev/null 2>&1; return; }
  cp -p "$stamp" "$W/CELL-$id.md.stamp.json"; cp -p "$stamp" "$W/stories/"
  # --- dispatch through the installed adapter ---
  ( cd "$W" && bash "$DISPATCH" "stories/CELL-$id.md" 1 > "$cdir/dispatch.log" 2>&1 ); local drc=$?
  local handle; handle="$(grep -oE 'launched in Orca terminal term_[0-9a-f-]+' "$cdir/dispatch.log" | grep -oE 'term_[0-9a-f-]+' | head -1)"
  # --- independent gate + measurements ---
  local gate="FAIL" gline; gline="$(cd "$W" && bash "spike/gates/gate-$task.sh" 2>&1 | head -1)"; [[ "$gline" == GATE\ PASS* ]] && gate="PASS"
  local pb=0 sb rb=0 pf="$W/stories/CELL-$id.md.prompt"
  [[ -n "$persona_file" && -f "$persona_file" ]] && pb=$(wc -c < "$persona_file"); sb=$(wc -c < "$W/stories/CELL-$id.md"); [[ -f "$pf" ]] && rb=$(wc -c < "$pf")
  local window="null"; if [[ "$preq" == "true" ]]; then window="$(yq -r ".profiles.\"$profile\".min_context // \"null\"" "$CATALOG")"; fi
  local cr="$W/stories/CELL-$id.md.claude-result.json" env_json='null'
  if [[ -f "$cr" ]]; then cp -p "$cr" "$cdir/claude-result.json"; env_json="$(jq -c '{is_error, num_turns, duration_ms, stop_reason, denials:(.permission_denials|length), model_usage:(.modelUsage|to_entries|map({model:.key, contextWindow:.value.contextWindow, inputTokens:.value.inputTokens, outputTokens:.value.outputTokens, cacheRead:.value.cacheReadInputTokens, cacheCreation:.value.cacheCreationInputTokens}))}' "$cr" 2>/dev/null || echo null)"; [[ "$window" == "null" ]] && window="$(jq -r '[.modelUsage[]?.contextWindow] | max // "null"' "$cr")"; fi
  [[ -f "$W/stories/CELL-$id.md.result.json" ]] && cp -p "$W/stories/CELL-$id.md.result.json" "$cdir/result.json"
  cp -p "$W/stories/CELL-$id.md" "$cdir/story.md"; [[ -f "$pf" ]] && cp -p "$pf" "$cdir/prompt.txt"
  [[ -n "$handle" ]] && orca-ide terminal read --terminal "$handle" --json > "$cdir/terminal-buffer.json" 2>/dev/null
  local payload_bytes=$((pb+sb+rb)) est; est=$(( (payload_bytes+3)/4 ))
  jq -n --arg id "$id" --arg h "$harness" --arg p "$profile" --arg mode "$mode" --arg task "$task" --arg gate "$gate" --arg gline "$gline" --argjson drc "$drc" --argjson pb "$pb" --argjson sb "$sb" --argjson rb "$rb" --argjson est "$est" --argjson win "$window" --argjson env "$env_json" --arg ov "$override" --arg t "$(now)" --argjson secs "$(( $(date +%s)-t0 ))" \
    '{cell:$id, harness:$h, profile:$p, mode:$mode, task:$task, status:(if $drc==0 then "done" else "gates_failed_or_error" end), dispatch_exit:$drc, gate:$gate, gate_line:$gline, override:$ov, window_tokens:$win, payload:{persona_bytes:$pb, story_bytes:$sb, prompt_bytes:$rb, bytes:($pb+$sb+$rb), tokens_est_bytes4:$est, ratio:(if $win==null or $win==0 then null else ($est/$win) end), headroom_tokens:(if $win==null then null else ($win-$est) end)}, envelope:$env, wall_seconds:$secs, finished_at:$t}' > "$out"
  # --- cleanup ---
  [[ -n "$handle" ]] && orca-ide terminal close --terminal "$handle" --json >/dev/null 2>&1
  orca-ide worktree rm --worktree "$wsel" --force --json >/dev/null 2>&1
  echo "CELL $id $harness/$profile mode=$mode task=$task gate=$gate drc=$drc override=$override est=${est}tok win=$window secs=$(( $(date +%s)-t0 ))"
}
for c in "$@"; do run_cell "$c"; done
echo "CELLS DONE: $#"
