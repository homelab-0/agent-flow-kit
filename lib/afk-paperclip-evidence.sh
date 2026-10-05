#!/usr/bin/env bash
# afk-paperclip-evidence.sh — `paperclip-evidence`: the content snapshot and
# the write-once attempt, launch and outcome records of a canonical Paperclip
# dispatch (AFK-PC evidence foundation). Collection only: nothing here decides
# readiness, publishes a final, or talks to Paperclip. See docs/PAPERCLIP.md.
# Needs lib/afk-accept.sh. SOURCED, never executed.

if [[ -n "${AFK_PCE_SOURCED:-}" ]]; then
  return 0
fi
AFK_PCE_SOURCED=1

AFK_PCE_SID_RE='^HOM-[0-9]+\.S[0-9]+$'
AFK_PCE_NUM_RE='^[1-9][0-9]{0,8}$'
AFK_PCE_DISPATCH_RE='^[A-Za-z0-9:._-]{1,200}$'

afk_pce_emit() { # <json_mode> <result> [<extra-json>]
  local x="${3:-}"; [[ -n "$x" ]] || x='{}'
  if [[ "$1" == true ]]; then
    jq -nc --arg r "$2" --argjson x "$x" '{result:$r} + $x'
  elif [[ "$2" == ok ]]; then
    jq -r 'to_entries | map("\(.key)=\(.value | tostring)") | "ok " + join(" ")' <<<"$x"
  else
    printf 'agent-flow-kit paperclip-evidence: %s\n' "$2"
  fi
}

afk_pce_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# afk_pce_snapshot <dir> -- prints afk-snapshot/1 {base_commit, tree}: the
# tree a commit of this worktree would record, built in a disposable index.
# All tracked content (HEAD and the real index) and every untracked file that
# is not ignored are included. Nothing is excluded by name: the private
# artifact scope (stories, specs, stamps, results) is the repository's ignored
# .pm-brief/ directory, the same for every session, and anything outside it is
# product. HEAD, refs, the real index and the worktree files are never
# written; objects go to the object store, and configured clean filters run
# as for `git add`. Ignored files are outside the snapshot, as they are
# outside any commit. Any failure prints nothing and returns 1.
afk_pce_snapshot() {
  local dir="$1" top base="" real_index tmp idx tree rc=0 p
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" && [[ -d "$top" ]] || return 1
  base="$(git -C "$top" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || base=""
  real_index="$(git -C "$top" rev-parse --git-path index 2>/dev/null)" || return 1
  [[ "$real_index" == /* ]] || real_index="$top/$real_index"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/afk-snapshot.XXXXXXXX")" || return 1
  idx="$tmp/index"
  (
    g() { GIT_INDEX_FILE="$idx" git -C "$top" --literal-pathspecs "$@"; }
    if [[ -n "$base" ]]; then
      # A pristine index read from HEAD, never a copy of the real one: a copy
      # would carry its assume-unchanged and skip-worktree bits, and `add -A`
      # would then skip worktree edits to those paths. Every tracked file is
      # rehashed instead.
      g read-tree "$base" || exit 1
    else
      g read-tree --empty || exit 1
    fi
    g add -A -- . 2>/dev/null || exit 1
    # Files tracked only in the real index (staged, never committed), even
    # when an ignore rule matches them. Read, never written: the real index is
    # only ever listed.
    GIT_INDEX_FILE="$real_index" git -C "$top" ls-files -z 2>/dev/null >"$tmp/staged" || exit 1
    : >"$tmp/add"
    while IFS= read -r -d '' p; do
      [[ -e "$top/$p" || -L "$top/$p" ]] && printf '%s\0' "$p" >>"$tmp/add"
    done <"$tmp/staged"
    if [[ -s "$tmp/add" ]]; then
      g add -f --pathspec-from-file="$tmp/add" --pathspec-file-nul 2>/dev/null || exit 1
    fi
    g write-tree 2>/dev/null >"$tmp/tree"
  ) >/dev/null 2>&1 || rc=1
  tree="$(cat "$tmp/tree" 2>/dev/null)"
  rm -rf -- "$tmp"
  (( rc == 0 )) && [[ "$tree" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  jq -nc --arg b "$base" --arg t "$tree" \
    '{schema:"afk-snapshot/1", base_commit:(if $b == "" then null else $b end), tree:$t}'
}

# afk_pce_snapshot_ok <json> -- a well-formed snapshot (or the literal null a
# failed snapshot is recorded as).
afk_pce_snapshot_ok() {
  jq -e 'type == "null" or (type == "object" and .schema == "afk-snapshot/1"
          and (.tree | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))
          and (.base_commit == null or (.base_commit | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))))' \
    <<<"$1" >/dev/null 2>&1
}

# afk_pce_tuple_ok <json> -- the acceptance tuple route-accept emits.
afk_pce_tuple_ok() {
  jq -e --arg sid "$AFK_PCE_SID_RE" 'type == "object" and (keys == ["decision_digest","issue","plan_digest","plan_story_sha256","stamp_sha256","story_id"])
          and (.issue | type == "string") and (.story_id | type == "string" and test($sid))
          and (.decision_digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
          and (.plan_digest | type == "string" and test("^[0-9a-f]{64}$"))
          and (.plan_story_sha256 | type == "string" and test("^sha256:[0-9a-f]{64}$"))
          and (.stamp_sha256 | type == "string" and test("^sha256:[0-9a-f]{64}$"))' <<<"$1" >/dev/null 2>&1 &&
    afk_pc_uuid_ok "$(jq -r .issue <<<"$1")"
}

# afk_pce_dir <issue> <story_id> [create] -- the attempt directory, outside
# any worktree. Refuses an unsafe id and any symlinked level.
afk_pce_dir() {
  local issue="$1" sid="$2" create="${3:-false}" root d
  afk_pc_uuid_ok "$issue" && [[ "$sid" =~ $AFK_PCE_SID_RE ]] || return 1
  [[ "$AFK_STATE_DIR" == /* ]] || return 1
  root="$AFK_STATE_DIR/paperclip/attempts"
  if [[ "$create" == true ]]; then
    mkdir -p -- "$root/$issue/$sid" 2>/dev/null || return 1
  fi
  for d in "$AFK_STATE_DIR/paperclip" "$root" "$root/$issue" "$root/$issue/$sid"; do
    [[ -L "$d" ]] && return 1
    [[ -e "$d" && ! -d "$d" ]] && return 1
  done
  printf '%s' "$root/$issue/$sid"
}

# afk_pce_create_once <path> <json> -- write-once: the record is fully written
# to a private temp file and then hard-linked into place. A link never
# replaces an existing name, so the first creator wins, a duplicate fails
# (rc 3), and no reader ever sees a partial record under the final name.
afk_pce_create_once() {
  local final="$1" tmp
  tmp="$(dirname -- "$final")/.tmp.$$.$RANDOM.$(basename -- "$final")"
  if ! ( umask 077 && set -C && printf '%s\n' "$2" >"$tmp" ) 2>/dev/null; then
    rm -f -- "$tmp"; return 1
  fi
  if ln -- "$tmp" "$final" 2>/dev/null; then rm -f -- "$tmp"; return 0; fi
  rm -f -- "$tmp"
  [[ -e "$final" || -L "$final" ]] && return 3
  return 1
}

# afk_pce_numbers <dir> <name-regex-with-one-group> -- the integers captured
# by the group, one per line, numerically sorted. Never a lexical or
# timestamp order.
afk_pce_numbers() {
  local f n re="$2"
  for f in "$1"/*; do
    [[ -e "$f" ]] || continue
    f="${f##*/}"
    [[ "$f" =~ $re ]] || continue
    n="${BASH_REMATCH[1]}"
    [[ "$n" =~ $AFK_PCE_NUM_RE ]] && printf '%s\n' "$n"
  done | sort -n
}

afk_pce_max() { afk_pce_numbers "$@" | tail -n 1; }

# afk_pce_allocate <dir> <issue> <sid> <tuple> <acceptance-json> -- the next
# attempt number, by write-once creation of <N>.accept.json. Concurrent
# callers each get a distinct N. Prints N.
afk_pce_allocate() {
  local dir="$1" n tries rec rc
  n="$(afk_pce_max "$dir" '^([0-9]+)\.accept\.json$')"; n=$(( ${n:-0} + 1 ))
  for (( tries = 0; tries < 64; tries++ )); do
    rec="$(jq -nc --arg i "$2" --arg s "$3" --argjson n "$n" --argjson t "$4" --argjson a "$5" --arg at "$(afk_pce_now)" \
      '{schema:"afk-paperclip-attempt/1", kind:"accept", issue:$i, story_id:$s, attempt:$n, tuple:$t, acceptance:$a, created_at:$at}')" || return 1
    afk_pce_create_once "$dir/$n.accept.json" "$rec"; rc=$?
    (( rc == 0 )) && { printf '%s' "$n"; return 0; }
    (( rc == 3 )) || return 1
    n=$(( n + 1 ))
  done
  return 1
}

# afk_pce_record_accept <story> <acceptance-json> -- called by route-accept on
# a successful pm-auto acceptance, with AFK_ACC_* loaded and the plan read
# (AFK_ACC_TUPLE). Prints the allocated attempt number.
afk_pce_record_accept() {
  local dir
  afk_pce_tuple_ok "$AFK_ACC_TUPLE" || return 1
  dir="$(afk_pce_dir "$AFK_ACC_ISSUE" "$AFK_ACC_SID" true)" || return 1
  afk_pce_allocate "$dir" "$AFK_ACC_ISSUE" "$AFK_ACC_SID" "$AFK_ACC_TUPLE" "$2"
}

# afk_pce_current_tuple <story> -- re-runs the authoritative verification and
# prints the current tuple, or prints the refusal reason and returns 1.
afk_pce_current_tuple() {
  local r
  if ! afk_accept_load "$1"; then printf '%s' "$AFK_ACC_REASON"; return 1; fi
  [[ "$AFK_ACC_PAPERCLIP" == true ]] || { printf PM_AUTO_NOT_PAPERCLIP; return 1; }
  r="$(afk_accept_verify "$1")"
  [[ "$r" == ok ]] || { printf '%s' "${r:-ACCEPTANCE_UNCHECKABLE}"; return 1; }
  afk_accept_plan_read
  [[ "$AFK_ACC_PLAN_REASON" == ok ]] || { printf '%s' "$AFK_ACC_PLAN_REASON"; return 1; }
  printf '%s' "$AFK_ACC_TUPLE"
}

# ---- Review verdicts (docs/PAPERCLIP.md, "Review verdicts") ----------------

AFK_PCE_VERDICT_MAX=65536
# afk-review-verdict/1, exactly these members: no member is optional, none is
# coerced, and an unknown member makes the verdict invalid.
AFK_PCE_VERDICT_SHAPE='type == "object"
  and keys == ["findings","reviewer_story_id","reviews_story_id","schema","verdict"]
  and .schema == "afk-review-verdict/1"
  and (.reviewer_story_id | type == "string") and (.reviews_story_id | type == "string")
  and (.verdict == "APPROVE" or .verdict == "CHANGES_REQUESTED")
  and (.findings | type == "array")
  and all(.findings[]; type == "object" and keys == ["severity","status","summary"]
        and (.severity == "blocker" or .severity == "major" or .severity == "minor" or .severity == "info")
        and (.status == "open" or .status == "resolved")
        and (.summary | type == "string"))'

# afk_pce_review_role <tuple> -- the review role of the tuple's own story. The
# story is the stored record's entry whose projection hashes to the tuple's
# plan_story_sha256, so its role and target are the approved bytes even when
# other parts of the record were edited. Prints the target builder id and
# returns 0 for a reviewer bound to its plan (the record carries plan_digest,
# is /2 and re-renders to that digest); returns 2 for a story whose role is
# reviewer but whose plan binding fails; returns 1 for any other story.
afk_pce_review_role() {
  local t="$1" issue pd rec story target plan
  issue="$(jq -r '.issue // empty' <<<"$t" 2>/dev/null)"; pd="$(jq -r '.plan_digest // empty' <<<"$t" 2>/dev/null)"
  afk_pc_uuid_ok "$issue" && [[ "$pd" =~ ^[0-9a-f]{64}$ ]] || return 1
  rec="$AFK_STATE_DIR/paperclip/plans/$issue.json"
  [[ -f "$rec" && ! -L "$rec" ]] || return 1
  story="$(jq -c --arg s "$(jq -r .story_id <<<"$t")" '[.stories[]? | select(.id == $s)] | first // empty' "$rec" 2>/dev/null)"
  [[ -n "$story" && "$(jq -cS . <<<"$story" | afk_sha256_stdin)" == "$(jq -r .plan_story_sha256 <<<"$t")" ]] || return 1
  jq -e '.role == "reviewer"' <<<"$story" >/dev/null 2>&1 || return 1
  target="$(jq -r '.reviews | strings' <<<"$story" 2>/dev/null)"
  printf '%s' "$target"
  plan="$(jq -ce --arg d "$pd" 'select(type == "object" and .digest == $d and .plan_schema == "afk-paperclip-plan/2")
    | {schema:.plan_schema, repo, base, stories}' "$rec" 2>/dev/null)" &&
    [[ -n "$target" && "$(afk_pcp_digest "$plan" 2>/dev/null)" == "$pd" ]] || return 2
}

# afk_pce_verdict_judge <tuple-or-empty> <verdict-text-json> -- the one verdict
# check, used by `review-verdict --check` and by the outcome verb's review
# record. The text arrives as a JSON string, encoded by the same `head -c
# 65537 | jq -Rs .` in both callers; empty means nothing is at the verdict
# path. Sets AFK_PCE_VERDICT (the valid verdict object, else null) and
# AFK_PCE_REASONS (a JSON array, empty on a pass). Returns 0 on a pass.
afk_pce_verdict_judge() {
  local tuple="$1" vjs="$2" text v="" target issue appr
  AFK_PCE_VERDICT=null AFK_PCE_REASONS='[]'
  [[ -n "$vjs" ]] || { AFK_PCE_REASONS='["VERDICT_MISSING"]'; return 1; }
  # The bytes: at most the limit, no NUL, valid UTF-8 (an invalid byte becomes
  # U+FFFD in the encoding, so a literal U+FFFD is refused as well).
  if jq -e --argjson m "$AFK_PCE_VERDICT_MAX" \
       'type == "string" and utf8bytelength <= $m and (explode | all(. != 0 and . != 65533))' <<<"$vjs" >/dev/null 2>&1; then
    text="$(jq -j . <<<"$vjs"; printf x)"; text="${text%x}"
    # Exactly one JSON value, an object, and no duplicate member: the parsed
    # object must stream exactly as the text does.
    v="$(jq -cs 'select(length == 1 and (.[0] | type) == "object") | .[0]' <<<"$text" 2>/dev/null)" || v=""
    [[ -n "$v" && "$(jq -cn --stream '[inputs]' <<<"$text" 2>/dev/null)" == "$(jq -c '[tostream]' <<<"$v" 2>/dev/null)" ]] || v=""
  fi
  if [[ -z "$v" ]] || ! jq -e "$AFK_PCE_VERDICT_SHAPE" <<<"$v" >/dev/null 2>&1; then
    AFK_PCE_REASONS='["VERDICT_INVALID"]'; return 1
  fi
  AFK_PCE_VERDICT="$v"
  # Bound only to the current approval of the tuple's plan digest, and to a
  # /2 reviewer story of that plan.
  issue="$(jq -r '.issue // empty' <<<"${tuple:-null}" 2>/dev/null)"
  if [[ -z "$tuple" ]] || ! afk_pce_tuple_ok "$tuple"; then AFK_PCE_REASONS='["VERDICT_PLAN_UNBOUND"]'; return 1; fi
  appr="$(afk_cmd_paperclip_approval true "$issue" 2>/dev/null)" || appr=""
  if ! jq -e --arg d "$(jq -r .plan_digest <<<"$tuple")" '.approved == true and .digest == $d' <<<"${appr:-null}" >/dev/null 2>&1 ||
     ! target="$(afk_pce_review_role "$tuple")"; then
    AFK_PCE_REASONS='["VERDICT_PLAN_UNBOUND"]'; return 1
  fi
  AFK_PCE_REASONS="$(jq -c --arg r "$(jq -r .story_id <<<"$tuple")" --arg t "$target" '[
    (if .reviewer_story_id != $r or .reviews_story_id != $t then "VERDICT_IDS_MISMATCH" else empty end),
    (if .verdict != "APPROVE" then "VERDICT_NOT_APPROVE" else empty end),
    (if any(.findings[]; (.severity == "blocker" or .severity == "major") and .status == "open")
       then "VERDICT_OPEN_MAJOR" else empty end)]' <<<"$v")" || AFK_PCE_REASONS='["VERDICT_INVALID"]'
  [[ "$AFK_PCE_REASONS" == '[]' ]]
}

afk_pce_verdict_emit() { # <json_mode> <reasons-json> [<extra-json>]
  local x="${3:-}"; [[ -n "$x" ]] || x='{}'
  if [[ "$1" == true ]]; then
    jq -nc --argjson r "$2" --argjson x "$x" '{result:($r[0] // "ok"), reasons:$r} + $x'
  elif [[ "$2" == '[]' ]]; then
    printf 'review verdict: ok\n'
  else
    jq -r '"agent-flow-kit review-verdict: " + join(" ")' <<<"$2"
  fi
}

# afk_cmd_review_verdict <json_mode> -- `review-verdict --check`, the gate a /2
# reviewer story runs. AFK_GATE_STORY, set by dispatch.sh for each gate, only
# locates the story: the tuple, the approval and the plan roles all come from
# kit state, so a wrong locator fails closed. Exit 0 only on a pass, else 4.
afk_cmd_review_verdict() {
  local jm="$1" story="${AFK_GATE_STORY:-}" vf tuple why="" vjs=""
  if [[ "$story" != /* || ! -f "$story" || -L "$story" ]]; then
    afk_pce_verdict_emit "$jm" '["GATE_STORY_INVALID"]'; return 4
  fi
  # Read exactly as dispatch.sh's paperclip_capture_verdict reads: nothing at
  # the path is missing; a symlink or non-regular file is present but has no
  # bytes (invalid); a regular file is encoded up to one byte past the limit.
  vf="$story.verdict.json"
  if [[ -L "$vf" || ( -e "$vf" && ! -f "$vf" ) ]]; then
    vjs='""'
  elif [[ -f "$vf" ]]; then
    vjs="$(head -c $((AFK_PCE_VERDICT_MAX + 1)) -- "$vf" | jq -Rs . 2>/dev/null)" || vjs=""
    [[ -n "$vjs" ]] || vjs='""'
  fi
  if ! tuple="$(afk_pce_current_tuple "$story")"; then why="$tuple"; tuple=""; fi
  if afk_pce_verdict_judge "$tuple" "$vjs"; then
    afk_pce_verdict_emit "$jm" '[]' "$(jq -nc --arg s "$(jq -r .story_id <<<"$tuple")" '{reviewer_story_id:$s}')"
    return 0
  fi
  [[ "$AFK_PCE_REASONS" == '["VERDICT_PLAN_UNBOUND"]' ]] || why=""
  afk_pce_verdict_emit "$jm" "$AFK_PCE_REASONS" \
    "$(jq -nc --arg w "$why" 'if $w == "" then {} else {tuple_reason:$w} end')"
  return 4
}

# afk_pce_read_record <path> <kind> -- one JSON object of this kind, or fail.
afk_pce_read_record() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  jq -ce --arg k "$2" 'select(type == "object" and .schema == "afk-paperclip-attempt/1" and .kind == $k)' "$1" 2>/dev/null
}

# afk_pce_launch <json_mode> <story> <cycle> <dispatch_id> -- stdin is
# {tuple, snapshot}: the tuple dispatch.sh received from route-accept --verify
# and the launch snapshot. Re-verifies; links the launch to the newest
# accepted attempt. Writes <N>.c<k>.launch.json once.
afk_pce_launch() {
  local jm="$1" story="$2" cycle="$3" did="$4" in tuple snap now issue sid dir n acc rec x rc
  [[ "$cycle" =~ $AFK_PCE_NUM_RE && "$did" =~ $AFK_PCE_DISPATCH_RE && -f "$story" ]] ||
    { afk_pce_emit "$jm" EVIDENCE_ARGS_INVALID; return 1; }
  in="$(head -c 65536 | jq -ce 'select(type == "object")' 2>/dev/null)" || in=""
  tuple="$(jq -c '.tuple' <<<"${in:-null}" 2>/dev/null)"; snap="$(jq -c '.snapshot' <<<"${in:-null}" 2>/dev/null)"
  if [[ -z "$in" ]] || ! afk_pce_tuple_ok "$tuple" || ! afk_pce_snapshot_ok "$snap"; then
    afk_pce_emit "$jm" EVIDENCE_INPUT_INVALID; return 4
  fi
  now="$(afk_pce_current_tuple "$story")" || { afk_pce_emit "$jm" TUPLE_CHANGED "$(jq -nc --arg r "$now" '{reason:$r}')"; return 4; }
  jq -e --argjson a "$tuple" --argjson b "$now" '$a == $b' <<<null >/dev/null 2>&1 ||
    { afk_pce_emit "$jm" TUPLE_CHANGED '{"reason":"TUPLE_DIFFERS"}'; return 4; }
  issue="$(jq -r .issue <<<"$tuple")"; sid="$(jq -r .story_id <<<"$tuple")"
  dir="$(afk_pce_dir "$issue" "$sid")" || { afk_pce_emit "$jm" ATTEMPT_MISSING; return 4; }
  n="$(afk_pce_max "$dir" '^([0-9]+)\.accept\.json$')"
  [[ -n "$n" ]] || { afk_pce_emit "$jm" ATTEMPT_MISSING; return 4; }
  acc="$(afk_pce_read_record "$dir/$n.accept.json" accept)" &&
    jq -e --argjson n "$n" --arg i "$issue" --arg s "$sid" \
      '.attempt == $n and .issue == $i and .story_id == $s' <<<"$acc" >/dev/null 2>&1 ||
    { afk_pce_emit "$jm" RECORD_INVALID "$(jq -nc --argjson n "$n" '{attempt:$n}')"; return 4; }
  # Cycles under one attempt only move forward: a launch below the newest
  # launched cycle would run while `latest` still showed that newer cycle.
  x="$(afk_pce_max "$dir" "^$n\\.c([0-9]+)\\.launch\\.json\$")"
  if [[ -n "$x" ]] && (( cycle < x )); then
    afk_pce_emit "$jm" CYCLE_OUT_OF_ORDER "$(jq -nc --argjson n "$n" --argjson k "$cycle" --argjson m "$x" '{attempt:$n, cycle:$k, newest_cycle:$m}')"
    return 4
  fi
  rec="$(jq -nc --arg i "$issue" --arg s "$sid" --argjson n "$n" --argjson k "$cycle" \
    --arg d "$did" --argjson t "$tuple" --argjson sn "$snap" --argjson acc "$acc" --arg at "$(afk_pce_now)" \
    '{schema:"afk-paperclip-attempt/1", kind:"launch", issue:$i, story_id:$s, attempt:$n, cycle:$k,
      dispatch_id:$d, tuple:$t, accept_tuple_match:($acc.tuple == $t), snapshot:$sn, created_at:$at}')"
  afk_pce_create_once "$dir/$n.c$cycle.launch.json" "$rec"; rc=$?
  x="$(jq -nc --argjson n "$n" --argjson k "$cycle" '{attempt:$n, cycle:$k}')"
  case "$rc" in
    0) afk_pce_emit "$jm" ok "$x" ;;
    3) afk_pce_emit "$jm" LAUNCH_DUPLICATE "$x"; return 4 ;;
    *) afk_pce_emit "$jm" EVIDENCE_WRITE_FAILED "$x"; return 1 ;;
  esac
}

# afk_pce_outcome <json_mode> <story> <attempt> <cycle> <dispatch_id> -- stdin
# is {tuple, snapshots:{gate_pre, gate_post}, result_text}: result_text is the
# exact bytes dispatch.sh wrote to <story>.result.json, passed by the
# producer. No worktree result file is ever opened. The launch tuple is
# re-verified: a changed or refused tuple records APPROVAL_CHANGED, never a
# usable outcome. Writes <N>.c<k>.outcome.json once.
afk_pce_outcome() {
  local jm="$1" story="$2" n="$3" k="$4" did="$5" in tuple snaps text result dir launch now reason="" outcome rec x rc rsha
  [[ "$n" =~ $AFK_PCE_NUM_RE && "$k" =~ $AFK_PCE_NUM_RE && "$did" =~ $AFK_PCE_DISPATCH_RE && -f "$story" ]] ||
    { afk_pce_emit "$jm" EVIDENCE_ARGS_INVALID; return 1; }
  in="$(head -c 1048576 | jq -ce 'select(type == "object")' 2>/dev/null)" || in=""
  tuple="$(jq -c '.tuple' <<<"${in:-null}" 2>/dev/null)"
  snaps="$(jq -c '.snapshots' <<<"${in:-null}" 2>/dev/null)"
  text="$(jq -j '.result_text | strings' <<<"${in:-null}" 2>/dev/null; printf x)"; text="${text%x}"
  result="$(jq -ce 'select(type == "object")' <<<"$text" 2>/dev/null)" || result=""
  if [[ -z "$in" || -z "$text" ]] || ! afk_pce_tuple_ok "$tuple" ||
     ! jq -e 'type == "object" and (keys == ["gate_post","gate_pre"])' <<<"$snaps" >/dev/null 2>&1 ||
     ! afk_pce_snapshot_ok "$(jq -c .gate_pre <<<"$snaps")" || ! afk_pce_snapshot_ok "$(jq -c .gate_post <<<"$snaps")"; then
    afk_pce_emit "$jm" EVIDENCE_INPUT_INVALID; return 4
  fi
  if [[ -z "$result" || "$result" == *$'\n'* ]] ||
     ! jq -e --argjson k "$k" --arg d "$did" '(.status | type == "string") and .cycle == $k and .launch.dispatch_id == $d' \
       <<<"$result" >/dev/null 2>&1; then
    afk_pce_emit "$jm" RESULT_INVALID; return 4
  fi
  dir="$(afk_pce_dir "$(jq -r .issue <<<"$tuple")" "$(jq -r .story_id <<<"$tuple")")" ||
    { afk_pce_emit "$jm" LAUNCH_MISSING; return 4; }
  launch="$(afk_pce_read_record "$dir/$n.c$k.launch.json" launch)" ||
    { afk_pce_emit "$jm" LAUNCH_MISSING; return 4; }
  jq -e --argjson n "$n" --argjson k "$k" --arg d "$did" --argjson t "$tuple" \
    '.attempt == $n and .cycle == $k and .dispatch_id == $d and .tuple == $t' <<<"$launch" >/dev/null 2>&1 ||
    { afk_pce_emit "$jm" LAUNCH_FOREIGN; return 4; }
  outcome=RECORDED
  if ! now="$(afk_pce_current_tuple "$story")"; then
    outcome=APPROVAL_CHANGED; reason="$now"; now=null
  elif ! jq -e --argjson a "$tuple" --argjson b "$now" '$a == $b' <<<null >/dev/null 2>&1; then
    outcome=APPROVAL_CHANGED; reason=TUPLE_DIFFERS
  fi
  afk_sha256_stdin_v rsha < <(printf '%s' "$text") && [[ -n "$rsha" ]] || { afk_pce_emit "$jm" EVIDENCE_WRITE_FAILED; return 1; }
  rec="$(jq -nc --argjson l "$launch" --argjson now "$now" --arg o "$outcome" --arg why "$reason" \
    --argjson s "$snaps" --argjson r "$result" --arg rs "$rsha" --arg at "$(afk_pce_now)" \
    '{schema:"afk-paperclip-attempt/1", kind:"outcome", issue:$l.issue, story_id:$l.story_id,
      attempt:$l.attempt, cycle:$l.cycle, dispatch_id:$l.dispatch_id,
      outcome:$o, approval_reason:(if $why == "" then null else $why end),
      tuple:$l.tuple, tuple_at_outcome:$now,
      status:$r.status, gate_count:($r.gates // {} | length),
      gates_ok:(($r.gates | type) == "object" and ($r.gates | length) > 0 and ([$r.gates[]] | all(. == "pass"))),
      snapshots:{launch:$l.snapshot, gate_pre:$s.gate_pre, gate_post:$s.gate_post},
      result_sha256:$rs, result:$r, created_at:$at}')" || { afk_pce_emit "$jm" EVIDENCE_WRITE_FAILED; return 1; }
  afk_pce_create_once "$dir/$n.c$k.outcome.json" "$rec"; rc=$?
  x="$(jq -nc --argjson n "$n" --argjson k "$k" --arg o "$outcome" '{attempt:$n, cycle:$k, outcome:$o}')"
  case "$rc" in
    0) afk_pce_emit "$jm" ok "$x" ;;
    3) afk_pce_emit "$jm" OUTCOME_DUPLICATE "$x"; return 4 ;;
    *) afk_pce_emit "$jm" EVIDENCE_WRITE_FAILED "$x"; return 1 ;;
  esac
}

# afk_pce_latest <json_mode> <issue> <story_id> -- the newest record by the
# integer pair (attempt, cycle), surfaced as it is: an accepted attempt with
# no launch, or a launch with no outcome, is reported, never skipped for an
# older success. Not a readiness verdict.
afk_pce_latest() {
  local jm="$1" issue="$2" sid="$3" dir n k attempts acc launch out state x
  dir="$(afk_pce_dir "$issue" "$sid")" || { afk_pce_emit "$jm" EVIDENCE_ARGS_INVALID; return 1; }
  attempts="$(afk_pce_numbers "$dir" '^([0-9]+)\.accept\.json$' | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')"
  n="$(jq -r 'last // empty' <<<"$attempts")"
  x="$(jq -nc --arg i "$issue" --arg s "$sid" --argjson a "$attempts" '{issue:$i, story_id:$s, attempts:$a}')"
  if [[ -z "$n" ]]; then
    afk_pce_emit "$jm" ok "$(jq -c '. + {state:"STORY_EVIDENCE_MISSING"}' <<<"$x")"; return 0
  fi
  x="$(jq -c --argjson n "$n" '. + {attempt:$n}' <<<"$x")"
  acc="$(afk_pce_read_record "$dir/$n.accept.json" accept)" &&
    jq -e --argjson n "$n" '.attempt == $n' <<<"$acc" >/dev/null 2>&1 ||
    { afk_pce_emit "$jm" ok "$(jq -c '. + {state:"RECORD_INVALID", record:"accept"}' <<<"$x")"; return 0; }
  k="$(afk_pce_max "$dir" "^$n\\.c([0-9]+)\\.launch\\.json\$")"
  if [[ -z "$k" ]]; then
    afk_pce_emit "$jm" ok "$(jq -c --argjson acc "$acc" '. + {state:"ATTEMPT_NOT_LAUNCHED", tuple:$acc.tuple}' <<<"$x")"; return 0
  fi
  x="$(jq -c --argjson k "$k" '. + {cycle:$k}' <<<"$x")"
  launch="$(afk_pce_read_record "$dir/$n.c$k.launch.json" launch)" &&
    jq -e --argjson n "$n" --argjson k "$k" '.attempt == $n and .cycle == $k' <<<"$launch" >/dev/null 2>&1 ||
    { afk_pce_emit "$jm" ok "$(jq -c '. + {state:"RECORD_INVALID", record:"launch"}' <<<"$x")"; return 0; }
  if [[ ! -e "$dir/$n.c$k.outcome.json" ]]; then
    afk_pce_emit "$jm" ok "$(jq -c --argjson l "$launch" '. + {state:"ATTEMPT_UNFINISHED", dispatch_id:$l.dispatch_id,
      accept_tuple_match:$l.accept_tuple_match, snapshots:{launch:$l.snapshot}}' <<<"$x")"; return 0
  fi
  out="$(afk_pce_read_record "$dir/$n.c$k.outcome.json" outcome)" &&
    jq -e --argjson l "$launch" '.attempt == $l.attempt and .cycle == $l.cycle and .dispatch_id == $l.dispatch_id and .tuple == $l.tuple' \
      <<<"$out" >/dev/null 2>&1 ||
    { afk_pce_emit "$jm" ok "$(jq -c '. + {state:"RECORD_INVALID", record:"outcome"}' <<<"$x")"; return 0; }
  state=OUTCOME_RECORDED
  afk_pce_emit "$jm" ok "$(jq -c --arg st "$state" --argjson l "$launch" --argjson o "$out" \
    '. + {state:$st, dispatch_id:$o.dispatch_id, accept_tuple_match:$l.accept_tuple_match,
          outcome:$o.outcome, approval_reason:$o.approval_reason, status:$o.status,
          gates_ok:$o.gates_ok, gate_count:$o.gate_count, tuple:$o.tuple,
          snapshots:$o.snapshots, result_sha256:$o.result_sha256}' <<<"$x")"
}

afk_pce_usage() {
  cat <<'USAGE'
agent-flow-kit paperclip-evidence snapshot [--dir <path>] [--json]
agent-flow-kit paperclip-evidence launch --story <s> --cycle <k> --dispatch-id <id> [--json]   (stdin: {tuple, snapshot})
agent-flow-kit paperclip-evidence outcome --story <s> --attempt <n> --cycle <k> --dispatch-id <id> [--json]
    (stdin: {tuple, snapshots:{gate_pre, gate_post}, result_text})
agent-flow-kit paperclip-evidence latest --issue <uuid> --story-id <HOM-n.Sk> [--json]
USAGE
}

# afk_cmd_paperclip_evidence <verb> [options] -- parses its own closed option
# vocabulary. launch and outcome are dispatch.sh's calls; snapshot and latest
# are read-only.
afk_cmd_paperclip_evidence() {
  local verb="${1:-}" jm=false dir="." story="" cycle="" attempt="" did="" issue="" sid=""
  (( $# > 0 )) && shift
  case "$verb" in
    snapshot|launch|outcome|latest) ;;
    -h|--help|help) afk_pce_usage; return 0 ;;
    *) afk_warn "paperclip-evidence needs a verb: snapshot, launch, outcome or latest"; afk_pce_usage >&2; return 1 ;;
  esac
  while (( $# > 0 )); do
    case "$1" in
      --json) jm=true; shift; continue ;;
      --dir|--story|--cycle|--attempt|--dispatch-id|--issue|--story-id)
        if (( $# < 2 )); then afk_warn "$1 requires its declared value"; return 1; fi ;;
      *) afk_warn "'paperclip-evidence $verb' does not accept the argument '$(afk_safe_diagnostic "$1")'"; return 1 ;;
    esac
    case "$verb:$1" in
      snapshot:--dir) dir="$2" ;;
      launch:--story|outcome:--story) story="$2" ;;
      launch:--cycle|outcome:--cycle) cycle="$2" ;;
      outcome:--attempt) attempt="$2" ;;
      launch:--dispatch-id|outcome:--dispatch-id) did="$2" ;;
      latest:--issue) issue="$2" ;;
      latest:--story-id) sid="$2" ;;
      *) afk_warn "'paperclip-evidence $verb' does not accept the argument '$(afk_safe_diagnostic "$1")'"; return 1 ;;
    esac
    shift 2
  done
  case "$verb" in
    snapshot)
      local s
      if s="$(afk_pce_snapshot "$dir")"; then
        if [[ "$jm" == true ]]; then afk_pce_emit true ok "$(jq -c '{snapshot:.}' <<<"$s")"; else printf '%s\n' "$s"; fi
        return 0
      fi
      afk_pce_emit "$jm" SNAPSHOT_FAILED; return 1 ;;
    launch)
      [[ -n "$story" && -n "$cycle" && -n "$did" ]] || { afk_warn "paperclip-evidence launch needs --story, --cycle and --dispatch-id"; return 1; }
      afk_pce_launch "$jm" "$story" "$cycle" "$did" ;;
    outcome)
      [[ -n "$story" && -n "$attempt" && -n "$cycle" && -n "$did" ]] ||
        { afk_warn "paperclip-evidence outcome needs --story, --attempt, --cycle and --dispatch-id"; return 1; }
      afk_pce_outcome "$jm" "$story" "$attempt" "$cycle" "$did" ;;
    latest)
      [[ -n "$issue" && -n "$sid" ]] || { afk_warn "paperclip-evidence latest needs --issue and --story-id"; return 1; }
      afk_pce_latest "$jm" "$issue" "$sid" ;;
  esac
}
