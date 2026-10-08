#!/usr/bin/env bash
# afk-paperclip-evidence.sh — `paperclip-evidence`: the content snapshot and
# the write-once attempt, launch and outcome records of a canonical Paperclip
# dispatch (AFK-PC evidence foundation), and `paperclip-readiness`, their
# read-only reader. Nothing here publishes a final or talks to Paperclip, and
# nothing calls the reader automatically. See docs/PAPERCLIP.md.
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
  # A /2 reviewer's verdict must come from this cycle's worker and sit at an
  # ignored path (outside the snapshot, or writing it would move the tree the
  # review describes). A reviewer whose plan binding fails could never pass
  # its review gate, so it is refused too. All three refusals come before any
  # record, so they consume no cycle; only a deliberate removal clears a
  # verdict left from before, including one from an earlier cycle.
  local role="" vrc=0 vdir vabs
  afk_pce_review_role "$tuple" >/dev/null || vrc=$?
  if (( vrc != 1 )); then
    role=reviewer
    if [[ -e "$story.verdict.json" || -L "$story.verdict.json" ]]; then
      afk_pce_emit "$jm" VERDICT_PREEXISTS; return 4
    fi
    vdir="$(CDPATH='' cd -- "$(dirname -- "$story")" 2>/dev/null && pwd -P)" && vabs="$vdir/$(basename -- "$story").verdict.json" &&
      git -C "$vdir" check-ignore -q -- "$vabs" 2>/dev/null ||
      { afk_pce_emit "$jm" VERDICT_PATH_NOT_IGNORED; return 4; }
    (( vrc == 0 )) || { afk_pce_emit "$jm" VERDICT_PLAN_UNBOUND; return 4; }
  fi
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
  x="$(jq -nc --argjson n "$n" --argjson k "$cycle" --arg r "$role" '{attempt:$n, cycle:$k} + (if $r == "" then {} else {role:$r} end)')"
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
# usable outcome. Writes <N>.c<k>.outcome.json once. For a /2 reviewer story
# it first writes <N>.c<k>.review.json once, judged from the producer's
# verdict_text (a string, or null or absent when nothing was at the verdict
# path; any other type is EVIDENCE_INPUT_INVALID); any other story ignores
# verdict_text.
afk_pce_outcome() {
  local jm="$1" story="$2" n="$3" k="$4" did="$5" in tuple snaps text result dir launch now reason="" outcome rec x rc rsha
  local vjs="" vrc vsha="" check_ok review
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
  x="$(jq -nc --argjson n "$n" --argjson k "$k" --arg o "$outcome" '{attempt:$n, cycle:$k, outcome:$o}')"
  # The review record comes first: a stop between the two writes leaves no
  # outcome, so the cycle reads ATTEMPT_UNFINISHED, never a review-less pass.
  # A story whose approved role is reviewer gets one even when its plan
  # binding has since failed: the judge then records VERDICT_PLAN_UNBOUND.
  vrc=0; afk_pce_review_role "$tuple" >/dev/null || vrc=$?
  if (( vrc != 1 )); then
    case "$(jq -r '.verdict_text | type' <<<"$in" 2>/dev/null)" in
      string)
        vjs="$(jq -c '.verdict_text' <<<"$in" 2>/dev/null)"
        # Hashed from the pipe, never a shell variable, so no byte is dropped.
        afk_sha256_stdin_v vsha < <(jq -j '.verdict_text' <<<"$in" 2>/dev/null) && [[ -n "$vsha" ]] ||
          { afk_pce_emit "$jm" EVIDENCE_WRITE_FAILED "$x"; return 1; } ;;
      null) ;;
      *) afk_pce_emit "$jm" EVIDENCE_INPUT_INVALID "$x"; return 4 ;;
    esac
    check_ok=false
    afk_pce_verdict_judge "$tuple" "$vjs" && check_ok=true
    review="$(jq -nc --argjson l "$launch" --arg vs "$vsha" --argjson v "$AFK_PCE_VERDICT" --argjson ok "$check_ok" \
      --argjson why "$AFK_PCE_REASONS" --arg at "$(afk_pce_now)" \
      '{schema:"afk-paperclip-attempt/1", kind:"review", issue:$l.issue, story_id:$l.story_id,
        attempt:$l.attempt, cycle:$l.cycle, dispatch_id:$l.dispatch_id, tuple:$l.tuple,
        verdict_sha256:(if $vs == "" then null else $vs end), verdict:$v, check_ok:$ok, reasons:$why, created_at:$at}')" ||
      { afk_pce_emit "$jm" EVIDENCE_WRITE_FAILED "$x"; return 1; }
    afk_pce_create_once "$dir/$n.c$k.review.json" "$review"; rc=$?
    case "$rc" in
      0) ;;
      3) afk_pce_emit "$jm" REVIEW_DUPLICATE "$x"; return 4 ;;
      *) afk_pce_emit "$jm" EVIDENCE_WRITE_FAILED "$x"; return 1 ;;
    esac
  fi
  afk_pce_create_once "$dir/$n.c$k.outcome.json" "$rec"; rc=$?
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

# ---- Completion readiness (docs/PAPERCLIP.md, "Completion readiness") -----

# afk_pce_ready_read <path> <kind> -- exactly one JSON object of this kind in
# a regular, non-symlink file, or fail.
afk_pce_ready_read() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  jq -cse --arg k "$2" 'select(length == 1) | .[0]
    | select(type == "object" and .schema == "afk-paperclip-attempt/1" and .kind == $k)' "$1" 2>/dev/null
}

# afk_pce_ready_max <dir> <name-regex-with-one-group> -- the largest number,
# as afk_pce_max, except that a dangling link counts: a broken newest record
# is reported, never passed over for an older one.
afk_pce_ready_max() {
  local f n m="" re="$2"
  for f in "$1"/*; do
    [[ -e "$f" || -L "$f" ]] || continue
    f="${f##*/}"
    [[ "$f" =~ $re ]] || continue
    n="${BASH_REMATCH[1]}"
    [[ "$n" =~ $AFK_PCE_NUM_RE ]] && (( n > ${m:-0} )) && m="$n"
  done
  printf '%s' "$m"
}

# A well-formed question identity: none, or the id the poller sends with an
# integer seq. A ledger row the reader treats as active also says `working`
# or `waiting_human`, and a waiting_human row names its question. Anything
# else is LEDGER_NOT_ACTIVE.
AFK_PCE_QUESTION_SHAPE='.question_id == null
  or ((.question_id | type == "string" and test("^[A-Za-z0-9._:-]{1,64}$"))
      and (.question_seq | type == "number" and . >= 0 and . == floor))'
AFK_PCE_ROW_ACTIVE="(.state == \"working\" or (.state == \"waiting_human\" and .question_id != null))
  and ($AFK_PCE_QUESTION_SHAPE)"

# afk_pce_question_closed <ledger-row> <approved-digest-or-empty> <plan-record-or-empty>
# -- 0 when the row names no question, or its latest question is closed: a
# plan question (`plan-…`) only by the approval of record (its id is plan-
# plus the approved digest's first 8 characters, and the approved plan record
# names that question at the same posted seq); any other question only by a
# question_reply bound to its exact id and seq. Anything unreadable is open.
afk_pce_question_closed() {
  jq -e --arg pd "$2" --argjson p "${3:-null}" '
    (.question_id // null) as $q | (.question_seq // null) as $s
    | if $q == null then true
      elif ($q | type) != "string" or ($s | type) != "number" then false
      elif ($q | startswith("plan-")) then
        $pd != "" and $q == ("plan-" + $pd[0:8]) and ($p | type) == "object" and $p.digest == $pd
          and $p.question_id == $q and ($p.posted_seq | type) == "number" and $p.posted_seq == $s
      else (.question_reply | type) == "object" and .question_reply.question_id == $q
          and (.question_reply.question_seq | type) == "number" and .question_reply.question_seq == $s
      end' <<<"$1" >/dev/null 2>&1
}

AFK_PCE_FINAL_MAX=4096
# afk_pce_final_v2 <issue> <marker-path> -- 0 only for a strict
# afk-paperclip-final/2 marker of this issue: a regular, non-symlink file of
# at most 4 KiB of UTF-8 with no NUL or U+FFFD, holding exactly one JSON
# object with no duplicate member and exactly the members schema, entry_id (a
# UUID), issue (this issue) and evidence_set_sha256 (`sha256:` + 64 hex). Any
# other marker is legacy. Reads only; nothing here writes or delivers a final,
# and a /2 marker is no evidence of readiness by itself.
afk_pce_final_v2() {
  local issue="$1" f="$2" js text v
  [[ -f "$f" && ! -L "$f" ]] || return 1
  js="$(head -c $((AFK_PCE_FINAL_MAX + 1)) -- "$f" | jq -Rs . 2>/dev/null)" && [[ -n "$js" ]] || return 1
  jq -e --argjson m "$AFK_PCE_FINAL_MAX" \
    'type == "string" and utf8bytelength <= $m and (explode | all(. != 0 and . != 65533))' <<<"$js" >/dev/null 2>&1 || return 1
  text="$(jq -j . <<<"$js"; printf x)"; text="${text%x}"
  v="$(jq -cs 'select(length == 1 and (.[0] | type) == "object") | .[0]' <<<"$text" 2>/dev/null)" || v=""
  [[ -n "$v" && "$(jq -cn --stream '[inputs]' <<<"$text" 2>/dev/null)" == "$(jq -c '[tostream]' <<<"$v" 2>/dev/null)" ]] || return 1
  jq -e --arg i "$issue" 'keys == ["entry_id","evidence_set_sha256","issue","schema"]
    and .schema == "afk-paperclip-final/2" and (.entry_id | type == "string")
    and (.issue | type == "string") and .issue == $i
    and (.evidence_set_sha256 | type == "string" and test("^sha256:[0-9a-f]{64}$"))' <<<"$v" >/dev/null 2>&1 &&
    afk_pc_uuid_ok "$(jq -r .entry_id <<<"$v")"
}

afk_pce_common_dir() { # <path> -- the physical common Git directory
  local c
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [[ -d "$c" ]] &&
    (CDPATH='' cd -- "$c" 2>/dev/null && pwd -P)
}

# One story's reasons, from its newest records only. Inputs: $st (the approved
# story), $role/$target (from it), $pss (its plan_story_sha256), $pd, $i, $sid,
# $n/$k (the selected attempt and cycle), $acc/$l/$o/$rv (the records, null
# when absent; $rv a string when invalid) and $state.
AFK_PCE_READY_JQ="def vshape: $AFK_PCE_VERDICT_SHAPE;"'
def tree: if type == "object" and .schema == "afk-snapshot/1"
    and (.tree | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$")) then .tree else null end;
(($o | objects | .snapshots | objects) // {}) as $s
| ($s.launch | tree) as $tl | ($s.gate_pre | tree) as $tp | ($s.gate_post | tree) as $tq
| (($l | objects | .tuple | objects) // {}) as $lt
| (($o | objects | .result | objects | .gates | objects) // null) as $g
| (if $state != "OUTCOME_RECORDED" then [$state] else [
    (if $acc.attempt != $n or $acc.issue != $i or $acc.story_id != $sid
        or $l.attempt != $n or $l.cycle != $k or $l.issue != $i or $l.story_id != $sid
        or $o.attempt != $n or $o.cycle != $k or $o.issue != $i or $o.story_id != $sid
        or ($l.dispatch_id | type) != "string" or $o.dispatch_id != $l.dispatch_id or $s.launch != $l.snapshot
      then "RECORD_INVALID" else empty end),
    (if $o.outcome != "RECORDED" then "OUTCOME_NOT_RECORDED" else empty end),
    (if $o.status != "done" then "STORY_NOT_DONE" else empty end),
    (if $l.accept_tuple_match != true or $acc.tuple != $l.tuple or $o.tuple != $l.tuple
        or $o.tuple_at_outcome != $l.tuple then "TUPLE_MISMATCH" else empty end),
    (if $lt.issue != $i or $lt.story_id != $sid or $lt.plan_digest != $pd or $lt.plan_story_sha256 != $pss
      then "PLAN_BINDING_CHANGED" else empty end),
    (if $g == null or ($g | keys) != ($st.gates | unique) then "GATE_SET_MISMATCH"
     elif $o.gates_ok != true or ([$g[]] | all(. == "pass") | not) then "GATES_NOT_PASSED" else empty end),
    (if $tl == null or $tp == null or $tq == null then "SNAPSHOT_MISSING"
     elif $role == "builder" and $tp != $tq then "BUILDER_GATES_MUTATED"
     elif $role == "reviewer" and ($tl != $tp or $tp != $tq) then "REVIEW_TREE_MUTATED" else empty end),
    (if $role != "reviewer" then empty
     elif $rv == null then "REVIEW_MISSING"
     elif ($rv | type) != "object" then "REVIEW_INVALID"
     elif $rv.issue != $i or $rv.story_id != $sid or $rv.attempt != $n or $rv.cycle != $k
          or $rv.dispatch_id != $l.dispatch_id or $rv.tuple != $l.tuple then "REVIEW_FOREIGN"
     elif $rv.verdict == null and $rv.verdict_sha256 == null then "REVIEW_VERDICT_MISSING"
     elif ($rv.verdict | vshape | not) or ($rv.verdict_sha256 | type) != "string" then "REVIEW_INVALID"
     else ((if $rv.verdict.reviewer_story_id != $sid or $rv.verdict.reviews_story_id != $target
              then "REVIEW_IDS_MISMATCH" else empty end),
           (if $rv.verdict.verdict != "APPROVE" then "REVIEW_NOT_APPROVED" else empty end),
           (if any($rv.verdict.findings[]; (.severity == "blocker" or .severity == "major") and .status == "open")
              then "REVIEW_OPEN_MAJOR" else empty end)) end),
    (if $role == "reviewer" and ($rv | type) == "object" and $rv.check_ok != true then "REVIEW_CHECK_NOT_OK" else empty end),
    (if $role == "reviewer" and ((($g | objects | .[$rg]) // null) != "pass") then "REVIEW_GATE_NOT_PASSED" else empty end)
  ] end) as $why
| {story_id:$sid, role:$role, reviews:(if $role == "reviewer" then $target else null end), state:$state,
   attempt:$n, cycle:$k, dispatch_id:$l.dispatch_id, result_sha256:$o.result_sha256,
   verdict_sha256:(if ($rv | type) == "object" then $rv.verdict_sha256 else null end),
   launch_tree:$tl, tested_tree:$tq, reasons:$why, records:$recs}'

# afk_pce_ready_story <issue> <approved-digest> <approved-story-json> -- the
# story's newest attempt and its newest cycle, never an older success, as
# {story_id, role, ..., reasons, records}. records describe the selected
# accept/launch/outcome (and a reviewer's review) records by sha256 of their
# compact sorted-key JSON.
afk_pce_ready_story() {
  local issue="$1" pd="$2" st="$3" sid role target dir n="" k="" state="" acc=null launch=null out=null rev=null
  local pss recs='[]' kind obj h
  sid="$(jq -r .id <<<"$st")"; role="$(jq -r .role <<<"$st")"; target="$(jq -r '.reviews // ""' <<<"$st")"
  pss="$(jq -cS . <<<"$st" | afk_sha256_stdin)" || return 1
  if ! dir="$(afk_pce_dir "$issue" "$sid")"; then state=RECORD_INVALID
  elif n="$(afk_pce_ready_max "$dir" '^([0-9]+)\.accept\.json$')"; [[ -z "$n" ]]; then state=STORY_EVIDENCE_MISSING
  elif ! acc="$(afk_pce_ready_read "$dir/$n.accept.json" accept)"; then acc=null; state=RECORD_INVALID
  elif k="$(afk_pce_ready_max "$dir" "^$n\\.c([0-9]+)\\.launch\\.json\$")"; [[ -z "$k" ]]; then state=ATTEMPT_NOT_LAUNCHED
  elif ! launch="$(afk_pce_ready_read "$dir/$n.c$k.launch.json" launch)"; then launch=null; state=RECORD_INVALID
  elif [[ ! -e "$dir/$n.c$k.outcome.json" && ! -L "$dir/$n.c$k.outcome.json" ]]; then state=ATTEMPT_UNFINISHED
  elif ! out="$(afk_pce_ready_read "$dir/$n.c$k.outcome.json" outcome)"; then out=null; state=RECORD_INVALID
  else
    state=OUTCOME_RECORDED
    if [[ "$role" == reviewer && ( -e "$dir/$n.c$k.review.json" || -L "$dir/$n.c$k.review.json" ) ]]; then
      rev="$(afk_pce_ready_read "$dir/$n.c$k.review.json" review)" || rev='"invalid"'
    fi
    for kind in accept launch outcome review; do
      case "$kind" in accept) obj="$acc" ;; launch) obj="$launch" ;; outcome) obj="$out" ;; *) obj="$rev" ;; esac
      jq -e 'type == "object"' <<<"$obj" >/dev/null 2>&1 || continue
      h="$(jq -cS . <<<"$obj" | afk_sha256_stdin)" || return 1
      recs="$(jq -c --arg s "$sid" --argjson n "$n" --argjson k "$k" --arg kd "$kind" --arg h "$h" \
        '. + [{story_id:$s, attempt:$n, cycle:(if $kd == "accept" then null else $k end), kind:$kd, sha256:$h}]' <<<"$recs")"
    done
  fi
  jq -nc --arg i "$issue" --arg pd "$pd" --arg pss "$pss" --arg sid "$sid" --arg role "$role" --arg target "$target" \
    --arg state "$state" --arg rg "$AFK_PCP_REVIEW_GATE" --argjson n "${n:-null}" --argjson k "${k:-null}" \
    --argjson st "$st" --argjson acc "$acc" --argjson l "$launch" --argjson o "$out" --argjson rv "$rev" \
    --argjson recs "$recs" "$AFK_PCE_READY_JQ"
}

# afk_pce_readiness <issue> <dir> <commit-or-empty> -- prints the readiness
# answer. Reads only: the ledger, the stop flag, the spool marker, the
# approval, the plan record and attempt records, and a snapshot of <dir>
# (whose scratch index is the only thing written, outside every repository
# file). Every applicable reason is collected; any reason means not ready.
afk_pce_readiness() {
  local issue="$1" dir="$2" commit="$3" why="" lpath="$AFK_STATE_DIR/paperclip/ledger.json" lg="" appr pd=""
  local pf="$AFK_STATE_DIR/paperclip/plans/$issue.json" rec="" plan="" body tree ctree own_c="" dir_c one st stories='[]'
  local spool r es h
  # The issue is active only while its ledger row is well formed and says
  # `working` or `waiting_human` (AFK_PCE_ROW_ACTIVE), and the host is not
  # stopped. The state alone never shows that a question was answered: that
  # is the QUESTION_OPEN check below, whatever the state. A legacy final in
  # any form is reported, never touched; only a strict /2 marker is not one.
  if [[ -f "$lpath" && ! -L "$lpath" ]]; then
    lg="$(jq -cse --arg id "$issue" 'select(length == 1) | .[0] | .issues[$id] | objects' "$lpath" 2>/dev/null)" || lg=""
  fi
  if [[ -z "$lg" || -e "${HOME:-}/.config/agent-flow-kit/paperclip/stop" || -L "${HOME:-}/.config/agent-flow-kit/paperclip/stop" ]] ||
     ! jq -e "$AFK_PCE_ROW_ACTIVE" <<<"$lg" >/dev/null 2>&1; then
    why+=$'LEDGER_NOT_ACTIVE\n'
  fi
  spool="$(afk_pc_spool_dir "$issue")"
  if { [[ -n "$lg" ]] && jq -e '.pending_final != null or .final_delivery_hold != null' <<<"$lg" >/dev/null 2>&1; } ||
     { [[ -e "$spool/.final" || -L "$spool/.final" ]] && ! afk_pce_final_v2 "$issue" "$spool/.final"; }; then
    why+=$'LEGACY_FINAL_PRESENT\n'
  fi
  # The approval of record, then the stored plan: /2, re-rendered to exactly
  # the approved digest with its schema line in the body, and valid roles.
  appr="$(afk_cmd_paperclip_approval true "$issue" 2>/dev/null)" || :
  pd="$(jq -r 'select(.approved == true) | .digest | strings' <<<"${appr:-null}" 2>/dev/null)" || pd=""
  [[ "$pd" =~ ^[0-9a-f]{64}$ ]] || { pd=""; why+=$'PLAN_NOT_APPROVED\n'; }
  if [[ -f "$pf" && ! -L "$pf" ]]; then rec="$(jq -cse 'select(length == 1) | .[0] | objects' "$pf" 2>/dev/null)" || rec=""; fi
  if [[ -z "$rec" ]]; then why+=$'PLAN_RECORD_INVALID\n'
  elif [[ "$(jq -r '.plan_schema // ""' <<<"$rec")" != afk-paperclip-plan/2 ]]; then why+=$'PLAN_HAS_NO_REVIEW_ROLES\n'
  elif [[ -n "$pd" ]]; then
    plan="$(jq -c '{schema:.plan_schema, repo, base, stories}' <<<"$rec")"
    body="$(afk_pcp_render "$plan" 2>/dev/null)" || body=""
    if [[ "$(jq -r '.digest // ""' <<<"$rec")" != "$pd" || "$(afk_pcp_digest "$plan" 2>/dev/null)" != "$pd" ]] ||
       ! grep -qx -e '- Plan schema: 2' <<<"$body"; then
      why+=$'PLAN_DIGEST_MISMATCH\n'; plan=""
    else
      one="$(afk_pcp_validate "$plan" "$(jq -r '.repo' <<<"$plan")" "$(jq -r '.stories[0].id | strings | split(".S")[0]' <<<"$plan" 2>/dev/null)")"
      [[ "$one" == ok ]] || { why+="$one"$'\n'; plan=""; }
    fi
  fi
  # The latest question the poller sent must be closed, in any state: a
  # resume or a promotion back to `working` keeps an unanswered question. A
  # malformed question identity is already LEDGER_NOT_ACTIVE.
  if [[ -n "$lg" ]] && jq -e "$AFK_PCE_QUESTION_SHAPE" <<<"$lg" >/dev/null 2>&1 &&
     ! afk_pce_question_closed "$lg" "$pd" "${rec:-null}"; then
    why+=$'QUESTION_OPEN\n'
  fi
  # The current product tree of the requested worktree, which must belong to
  # the issue's own repository; a supplied commit must record the same tree.
  tree="$(afk_pce_snapshot "$dir" 2>/dev/null | jq -r '.tree // empty' 2>/dev/null)" || tree=""
  [[ -n "$tree" ]] || why+=$'TREE_UNAVAILABLE\n'
  if afk_pcr_owner_repo "$issue" 2>/dev/null; then own_c="$(afk_pce_common_dir "$AFK_PCR_REPO_PATH")"; fi
  dir_c="$(afk_pce_common_dir "$dir")"
  if [[ -z "$own_c" ]]; then why+=$'OWNER_REPO_UNKNOWN\n'
  elif [[ "$own_c" != "$dir_c" ]]; then why+=$'WORKTREE_FOREIGN\n'; fi
  if [[ -n "$commit" ]]; then
    # Peel to a commit first: a bare tree id (or a tag of one) is not a commit.
    ctree="$(git -C "$dir" rev-parse -q --verify "$commit^{commit}^{tree}" 2>/dev/null)" || ctree=""
    [[ -n "$tree" && "$ctree" == "$tree" ]] || why+=$'COMMIT_TREE_MISMATCH\n'
  fi
  if [[ -n "$plan" ]]; then
    while IFS= read -r st; do
      one="$(afk_pce_ready_story "$issue" "$pd" "$st")" && [[ -n "$one" ]] || return 1
      stories="$(jq -c --argjson s "$one" '. + [$s]' <<<"$stories")"
    done < <(jq -c '.stories | sort_by(.id) | .[]' <<<"$plan")
  fi
  # Across stories: every builder tested the current tree; each reviewer is a
  # different dispatch that saw exactly its builder's tested tree.
  r="$(jq -nc --arg i "$issue" --arg pd "$pd" --arg t "$tree" --argjson st "$stories" \
    --argjson why "$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$why")" '
    (reduce $st[] as $x ({}; .[$x.story_id] = $x)) as $by
    | [ $why[],
        ($st[] | . as $x | (.reasons[] | "\(.):\($x.story_id)"),
          (if .state != "OUTCOME_RECORDED" or .tested_tree == null then empty
           elif .role == "builder" then (if $t != "" and .tested_tree != $t then "TREE_CHANGED:\(.story_id)" else empty end)
           else ($by[.reviews] // {}) as $b
             | ((if $b.dispatch_id != null and .dispatch_id == $b.dispatch_id then "REVIEW_NOT_INDEPENDENT:\(.story_id)" else empty end),
                (if $b.tested_tree != null and .launch_tree != $b.tested_tree then "REVIEW_TREE_MISMATCH:\(.story_id)" else empty end))
           end)),
        ([$st[].dispatch_id | strings] | group_by(.) | map(select(length > 1) | .[0]) | .[] | "DISPATCH_ID_REUSED:\(.)") ]
    | (reduce .[] as $r ([]; if any(.[]; . == $r) then . else . + [$r] end)) as $reasons
    | (($reasons | length) == 0 and ($st | length) > 0) as $ok
    | {ready:$ok, reasons:$reasons, issue:$i, plan_digest:(if $pd == "" then null else $pd end),
       tree:(if $t == "" then null else $t end), stories:[$st[] | del(.records, .launch_tree)],
       evidence_set:(if $ok then {schema:"afk-paperclip-evidence-set/1", issue:$i, plan_digest:$pd, tree:$t,
         records:([$st[].records[]] | sort_by([.story_id, .attempt, .cycle, .kind]))} else null end)}')" || return 1
  es="$(jq -cS '.evidence_set' <<<"$r")" || return 1
  h=""
  if [[ "$es" != null ]]; then h="$(printf '%s\n' "$es" | afk_sha256_stdin)" && [[ -n "$h" ]] || return 1; fi
  jq -c --arg h "$h" 'del(.evidence_set) + {evidence_set_sha256:(if $h == "" then null else $h end)}' <<<"$r"
}

# afk_cmd_paperclip_readiness [options] -- `paperclip-readiness --issue <uuid>
# --dir <worktree> [--commit <sha>] [--json]`, its own closed vocabulary.
# Exit 0 ready, 3 not ready, 1 usage or internal failure.
afk_cmd_paperclip_readiness() {
  local jm=false issue="" dir="" commit="" cset=false r
  while (( $# > 0 )); do
    case "$1" in
      --json) jm=true; shift; continue ;;
      --issue|--dir|--commit)
        if (( $# < 2 )); then afk_warn "$1 requires its declared value"; return 1; fi ;;
      *) afk_warn "'paperclip-readiness' does not accept the argument '$(afk_safe_diagnostic "$1")'"; return 1 ;;
    esac
    case "$1" in --issue) issue="$2" ;; --dir) dir="$2" ;; *) commit="$2"; cset=true ;; esac
    shift 2
  done
  if ! afk_pc_uuid_ok "$issue" || [[ -z "$dir" ]]; then
    afk_warn "paperclip-readiness needs --issue <uuid> and --dir <worktree>"; return 1
  fi
  # An explicit empty --commit is a usage error, never "no commit".
  [[ "$cset" == false || "$commit" =~ ^[0-9a-f]{7,64}$ ]] || { afk_warn "paperclip-readiness --commit takes a hex commit id"; return 1; }
  # Ambient repository redirection would point every git call at another
  # repository, both sides of the WORKTREE_FOREIGN check included, so the
  # reader runs without it; --dir and the owner's path alone locate Git.
  r="$(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
         GIT_ALTERNATE_OBJECT_DIRECTORIES; afk_pce_readiness "$issue" "$dir" "$commit")" && [[ -n "$r" ]] ||
    { afk_warn "paperclip-readiness: the evidence could not be evaluated"; return 1; }
  if [[ "$jm" == true ]]; then
    printf '%s\n' "$r"
  else
    jq -r 'if .ready then "ready tree=\(.tree) evidence_set_sha256=\(.evidence_set_sha256)"
           else "not ready: " + (.reasons | join(" ")) end' <<<"$r"
  fi
  [[ "$(jq -r .ready <<<"$r")" == true ]] || return "$AFK_EXIT_NOT_READY"
}

afk_pce_usage() {
  cat <<'USAGE'
agent-flow-kit paperclip-evidence snapshot [--dir <path>] [--json]
agent-flow-kit paperclip-evidence launch --story <s> --cycle <k> --dispatch-id <id> [--json]   (stdin: {tuple, snapshot})
    (the answer adds role:"reviewer" for a schema-2 reviewer story)
agent-flow-kit paperclip-evidence outcome --story <s> --attempt <n> --cycle <k> --dispatch-id <id> [--json]
    (stdin: {tuple, snapshots:{gate_pre, gate_post}, result_text[, verdict_text]})
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
