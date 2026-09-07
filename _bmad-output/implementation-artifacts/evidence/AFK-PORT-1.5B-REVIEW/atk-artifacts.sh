#!/usr/bin/env bash
# ATTACK 7 — artifact validation, identity, and the freshness check (AC-4).
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
source "$ROOT/files/model-router/scripts/dispatch.sh" 2>/dev/null || true
set +e   # dispatch.sh sets -e when sourced; this attack script must keep running
W=${TMP:-/tmp}/rev1.5b/art; rm -rf "$W"; mkdir -p "$W"
CK='completed current_state remaining_acceptance next_steps updated_at'
CT="$CK in_flight unretired_findings"
v() { # <label> <body> <schema> <members...>
  local l="$1" b="$2" s="$3"; shift 3
  if [[ "$b" == "@nofile" ]]; then rm -f "$W/x.json"; else printf '%s' "$b" > "$W/x.json"; fi
  printf '%-52s -> %s\n' "$l" "$(artifact_verdict "$W/x.json" "$s" $* || true)"
}
good='{"schema":"afk-checkpoint/1","completed":["a"],"current_state":"m","remaining_acceptance":["AC-1"],"next_steps":["n"],"updated_at":"2026-09-07T00:00:00Z"}'
echo "=== checkpoint schema ==="
v "valid"                       "$good" afk-checkpoint/1 $CK
v "absent file"                 "@nofile" afk-checkpoint/1 $CK
v "empty file"                  "" afk-checkpoint/1 $CK
v "not json"                    "hello" afk-checkpoint/1 $CK
v "truncated json"              '{"schema":' afk-checkpoint/1 $CK
v "a JSON array, not an object" '[1,2]' afk-checkpoint/1 $CK
v "a bare JSON string"          '"afk-checkpoint/1"' afk-checkpoint/1 $CK
v "JSON null"                   'null' afk-checkpoint/1 $CK
v "wrong schema id"             "${good/afk-checkpoint\/1/afk-checkpoint\/2}" afk-checkpoint/1 $CK
v "member present but null"     "${good/\"current_state\":\"m\"/\"current_state\":null}" afk-checkpoint/1 $CK
v "member present but EMPTY []" "${good/\"next_steps\":[\"n\"]/\"next_steps\":[]}" afk-checkpoint/1 $CK
v "member present but empty \"\"" "${good/\"current_state\":\"m\"/\"current_state\":\"\"}" afk-checkpoint/1 $CK
v "continuation body under checkpoint members" \
  '{"schema":"afk-checkpoint/1","completed":[],"current_state":"","remaining_acceptance":[],"next_steps":[],"updated_at":""}' afk-checkpoint/1 $CK
echo
echo "=== continuation schema (extra members) ==="
cgood='{"schema":"afk-continuation/1","completed":["a"],"current_state":"m","remaining_acceptance":["AC-1"],"next_steps":["n"],"updated_at":"t","in_flight":"gate","unretired_findings":[]}'
v "valid continuation" "$cgood" afk-continuation/1 $CT
v "checkpoint body offered as a continuation" "$good" afk-continuation/1 $CT
v "continuation missing in_flight" "${cgood/,\"in_flight\":\"gate\"/}" afk-continuation/1 $CT
echo
echo "NOTE: a shape-valid artifact whose every member is empty is VALID (disclosed"
echo "      in the record as 'validated for shape, not for usefulness')."
echo
echo "=== no member value ever reaches the identity that goes to the result ==="
printf '%s' "$cgood" > "$W/c.json"
id="$(artifact_identity_json "$W/c.json")"; echo "  identity: $id"
for probe in gate AC-1 afk-continuation completed; do
  grep -q "$probe" <<<"$id" && echo "  LEAK: [$probe] appears in the identity" || echo "  no leak of [$probe]"
done
echo "  sha matches the file: $([[ "$(jq -r .sha256 <<<"$id")" == "sha256:$(sha256sum "$W/c.json" | cut -d' ' -f1)" ]] && echo yes || echo NO)"
echo
echo "=== the freshness (ARTIFACT_STALE) identity check, transcribed from dispatch.sh ==="
grep -n -A3 'CONTINUATION_BEFORE" == "\$(sha256_of' "$ROOT/files/model-router/scripts/dispatch.sh"
stale_check() { # <before-sha> <after-sha> <verdict-in>
  local CONTINUATION_BEFORE="$1" after="$2" verdict="$3"
  if [[ "$verdict" == "VALID" && -n "$CONTINUATION_BEFORE" && "$CONTINUATION_BEFORE" == "$after" ]]; then verdict="ARTIFACT_STALE"; fi
  printf '  before=%-8s after=%-8s in=%-8s -> %s\n' "${1:-<none>}" "$2" "$3" "$verdict"
}
stale_check ""     aaa VALID
stale_check aaa    aaa VALID
stale_check aaa    bbb VALID
stale_check aaa    aaa ARTIFACT_MISSING
echo "  (row 2 is the refusal: a byte-identical artifact after the run was not written by this worker)"
echo
echo "=== the SAME freshness check does NOT exist for the checkpoint ==="
grep -c 'CHECKPOINT_BEFORE' "$ROOT/files/model-router/scripts/dispatch.sh" | sed 's/^/  occurrences of a checkpoint pre-launch sha: /'
grep -nE 'rm -f .\$result_file.|CHECKPOINT_FILE=|CONTINUATION_BEFORE=' "$ROOT/files/model-router/scripts/dispatch.sh" | sed 's/^/  /'
grep -Fn 'rm -f "$result_file"' "$ROOT/files/model-router/scripts/dispatch.sh" | sed 's/^/  /'
grep -Fn 'CHECKPOINT_FILE=' "$ROOT/files/model-router/scripts/dispatch.sh" | sed 's/^/  /'
grep -Fn 'CONTINUATION_BEFORE=' "$ROOT/files/model-router/scripts/dispatch.sh" | sed 's/^/  /'
echo "  (the result artifact IS removed pre-launch; the checkpoint is neither removed"
echo "   nor sha-captured, so a checkpoint left by an EARLIER cycle is reported as this"
echo "   cycle's checkpoint_artifact identity.)"
