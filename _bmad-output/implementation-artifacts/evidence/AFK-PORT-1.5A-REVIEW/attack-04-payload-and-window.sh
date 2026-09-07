#!/usr/bin/env bash
# ATTACK 4 — payload_refs edge cases and window resolution.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
setup_env
cat_with() { awk -v w="$2" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
             "$WORK/catalog.yaml" > "$1"; }
cat_with "$WORK/c.yaml" 100000000
export STUB_CATALOG="$WORK/c.yaml"

mkref() { head -c "$2" /dev/zero | tr '\0' 'z' > "$WT/$1"; }
mkref ref-a.txt 4000; mkref ref-b.txt 4000
mkdir -p "$WT/adir"; mkref adir/inner.txt 4000
ln -sf ref-a.txt "$WT/lnk-a.txt"   # name length matches ref-a.txt so fixtures stay equal-length
mkref outside-parent.txt 4000 && mv "$WT/outside-parent.txt" "$WORK/outside.txt"

story_with() { # <name> <payload_refs yaml inline>
  write_story "$WT/$1.md" "persona: dev
gates: [\"true\"]
payload_refs: $2"
  write_stamp "$WT/$1.md.stamp.json" high false
}
est_of() { bud .budget.estimate_tokens "$WT/$1.md.result.json" 2>/dev/null || echo "-"; }
run1() { reset_stubs; rm -f "$WT/$1.md.result.json" "$WT/$1.md.blocked"; run_dispatch "$1.md"; }

# baseline with no refs
write_story "$WT/base.md" "persona: dev
gates: [\"true\"]"; write_stamp "$WT/base.md.stamp.json" high false
rc="$(run1 base)"; eq "4: baseline dispatches" "$rc" "0"; B="$(est_of base)"

# Stories of IDENTICAL byte length whose ONLY difference is what they declare,
# so the estimate difference is exactly the payload difference. (A first pass of
# this attack compared stories of different lengths and mis-divided the
# remainder; this shape removes the arithmetic from the reviewer's side.)
: > "$WT/ref-0.txt"                       # zero bytes, name the same length as ref-a
story_with aa '[ref-a.txt, ref-a.txt]';   rc="$(run1 aa)"; eq "4: a story listing the same ref twice dispatches" "$rc" "0"
story_with bb '[ref-a.txt, ref-0.txt]';   rc="$(run1 bb)"; eq "4: a story listing one ref plus an empty file dispatches" "$rc" "0"
story_with cc '[ref-a.txt, ref-b.txt]';   rc="$(run1 cc)"; eq "4: a story listing two distinct refs dispatches" "$rc" "0"
story_with dd '[ref-a.txt, lnk-a.txt]'; rc="$(run1 dd)"; eq "4: a story listing a file and a symlink to it dispatches" "$rc" "0"
A="$(est_of aa)"; Bb="$(est_of bb)"; C="$(est_of cc)"; D="$(est_of dd)"
eq "4: the four fixtures really are the same length (control)" \
   "$(wc -c < "$WT/aa.md")|$(wc -c < "$WT/aa.md.prompt")" \
   "$(wc -c < "$WT/cc.md")|$(wc -c < "$WT/cc.md.prompt")"
printf '     (info) estimates: dup=%s a+empty=%s a+b=%s a+symlink=%s\n' "$A" "$Bb" "$C" "$D"
eq "4: the SAME ref listed twice is counted ONCE"                 "$A" "$Bb"
eq "4: a DISTINCT second ref adds exactly its 4000 bytes"          "$(( C - A ))" "1000"
eq "4: dedupe is on the RESOLVED path — symlink and target count once" "$D" "$A"

# --- refusals -------------------------------------------------------------
refuses() { # <name> <refs> <label>
  story_with "$1" "$2"; local rc; rc="$(run1 "$1")"
  if [[ "$rc" == "2" ]] && grep -q PAYLOAD_REF_MISSING "$WORK/err"; then
    ok "4: $3 REFUSES with PAYLOAD_REF_MISSING (config exit)"
  else bad "4: $3 REFUSES with PAYLOAD_REF_MISSING" "exit $rc; $(head -1 "$WORK/err")"; fi
  emptyfile "$STUB_STATE/curl-calls" "4: $3 made no placement call"
  emptyfile "$STUB_STATE/terminal-creates" "4: $3 created no terminal"
  nofile "$WT/$1.md.result.json" "4: $3 wrote no result"
}
refuses miss  '[ref-a.txt, nope.txt]'   "a missing ref"
refuses dir   '[adir]'                  "a directory"
refuses abs   "[$WT/ref-a.txt]"         "an ABSOLUTE path"
refuses abs2  '[/etc/hostname]'         "an absolute path outside the tree"
refuses dangl '[dangling.txt]'          "a dangling name"

# --- a path that ESCAPES the worktree via .. ------------------------------
story_with esc '[../outside.txt]'
rc="$(run1 esc)"
EE="$(est_of esc)"
printf '     (info) ../outside.txt: exit=%s estimate=%s (baseline story ~%s)\n' "$rc" "$EE" "$B"
if [[ "$rc" == "0" ]]; then
  bad "4: a payload_ref that ESCAPES the worktree is counted, not refused" \
      "exit 0, estimate includes the out-of-tree file — the record claims 'a path the worker could not read is not a path the estimate counts'"
else ok "4: an escaping payload_ref is refused (exit $rc)"; fi
# a dangling symlink pointing outside
ln -sf /nonexistent/zzz "$WT/dead-link.txt"
refuses deadl '[dead-link.txt]' "a dangling symlink"

# --- window resolution ----------------------------------------------------
# The stamp must never be the source. Put a min_context in the STAMP and a
# different one in the catalog; the result must carry the catalog's.
reset_stubs
write_story "$WT/w.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/w.md.stamp.json" high false
jq '. + {min_context: 999999, context_window: 999999, window_tokens: 999999}' "$WT/w.md.stamp.json" > "$WT/w.tmp" && mv "$WT/w.tmp" "$WT/w.md.stamp.json"
cat_with "$WORK/c2.yaml" 123456
rc="$(STUB_CATALOG="$WORK/c2.yaml" run_dispatch w.md)"
eq "4/window: dispatch proceeds" "$rc" "0"
eq "4/window: the CATALOG's value wins, not the stamp's" \
   "$(bud .budget.window_tokens "$WT/w.md.result.json")" "123456"
eq "4/window: window_source is CATALOG" "$(bud .budget.window_source "$WT/w.md.result.json")" "CATALOG"

# undeclared window on the shipped-shape catalog
reset_stubs; rm -f "$WT/w.md.result.json"
rc="$(STUB_CATALOG="$WORK/catalog.yaml" run_dispatch w.md)"
eq "4/undeclared: dispatch proceeds" "$rc" "0"
R="$WT/w.md.result.json"
eq "4/undeclared: state NOT_EVALUATED" "$(bud .budget.state "$R")" "NOT_EVALUATED"
eq "4/undeclared: reason CONTEXT_WINDOW_UNDECLARED" "$(bud .budget.reason "$R")" "CONTEXT_WINDOW_UNDECLARED"
eq "4/undeclared: window_tokens null" "$(bud '.budget.window_tokens|type' "$R")" "null"
eq "4/undeclared: ratio null" "$(bud '.budget.estimate_ratio|type' "$R")" "null"
eq "4/undeclared: NO findings" "$(bud '.budget.findings|length' "$R")" "0"
eq "4/undeclared: window_source still CATALOG" "$(bud .budget.window_source "$R")" "CATALOG"
eq "4/undeclared: the estimate is still reported" "$(bud '.budget.estimate_tokens > 0' "$R")" "true"
hasnt "4/undeclared: nothing appended to the story" "$(cat "$WT/w.md")" "SIZING_RISK"

# gateway class: CLAUDE_CODE_MAX_CONTEXT_TOKENS untouched by any of this
reset_stubs
write_story "$WT/gw.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/gw.md.stamp.json" high true local-code-standard
rc="$(STUB_CATALOG="$WORK/catalog.yaml" run_dispatch gw.md)"
eq "4/gateway: dispatches" "$rc" "0"
G="$(cat "$STUB_STATE/last-command.txt")"
has "4/gateway: CLAUDE_CODE_MAX_CONTEXT_TOKENS is the catalog's 65536" "$G" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536"
hasnt "4/gateway: the estimate never reaches the launch text" "$G" "estimate"
hasnt "4/gateway: no budget vocabulary in the launch text" "$G" "SIZING"
eq "4/gateway: window carried into the result" "$(bud .budget.window_tokens "$WT/gw.md.result.json")" "65536"
summary
