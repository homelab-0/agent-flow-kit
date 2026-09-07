#!/usr/bin/env bash
# ATTACK 1 — the frozen launch texts must be byte-identical to master's, for
# every class. Master's builders and HEAD's are sourced in SEPARATE shells and
# compared here by the reviewer, not by the story's own suite.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
T="$(mktemp -d /tmp/afk15a-bi.XXXXXX)"
git -C "$KIT_ROOT" show master:files/model-router/scripts/dispatch.sh > "$T/master.sh" || exit 1
git -C "$KIT_ROOT" show 39fd66c:files/model-router/scripts/dispatch.sh > "$T/base.sh" || exit 1

emit() { bash -c 'set -uo pipefail; . "$1"; shift; "$@"' _e "$@"; }
A=(/home/op /usr/bin:/bin op /wt/S.md.prompt claude-opus-5 high /wt/S.md.claude-result.json /wt/agents/dev.md)
G=(/home/op /usr/bin:/bin op /wt/S.md.prompt qwen36-27b high /wt/S.md.claude-result.json /wt/agents/dev.md https://gw.invalid op://v/i/credential /home/op/.op-agent-env cachyos-7900xtx 65536)
C=(/wt/S.md.prompt gpt-5.6-sol xhigh)

for eff in low medium high xhigh; do
  for base in "$T/master.sh" "$T/base.sh"; do
    n="$(basename "$base" .sh)"
    A2=("${A[@]}"); A2[5]="$eff"
    G2=("${G[@]}"); G2[5]="$eff"
    eq "native claude cmd identical to $n (effort $eff)" \
       "$(emit "$DISPATCH" build_claude_command "${A2[@]}")" "$(emit "$base" build_claude_command "${A2[@]}")"
    eq "gateway claude cmd identical to $n (effort $eff)" \
       "$(emit "$DISPATCH" build_claude_gateway_command "${G2[@]}")" "$(emit "$base" build_claude_gateway_command "${G2[@]}")"
    eq "codex cmd identical to $n (effort $eff)" \
       "$(emit "$DISPATCH" build_codex_command /wt/S.md.prompt gpt-5.6-sol "$eff")" \
       "$(emit "$base" build_codex_command /wt/S.md.prompt gpt-5.6-sol "$eff")"
  done
done

# CONTROLS — the comparison must be able to see a difference at all.
m="$(emit "$T/master.sh" build_claude_command "${A[@]}")"
[[ -n "$m" ]] && ok "CONTROL: master's builder produced non-empty text" || bad "CONTROL: master's builder produced non-empty text"
A3=("${A[@]}"); A3[4]="claude-sonnet-5"
if [[ "$(emit "$DISPATCH" build_claude_command "${A3[@]}")" != "$m" ]]; then
  ok "CONTROL: a perturbed model IS detected as different"
else bad "CONTROL: a perturbed model IS detected as different"; fi
G3=("${G[@]}"); G3[12]=131072
if [[ "$(emit "$DISPATCH" build_claude_gateway_command "${G3[@]}")" != "$(emit "$T/master.sh" build_claude_gateway_command "${G[@]}")" ]]; then
  ok "CONTROL: a perturbed gateway window IS detected as different"
else bad "CONTROL: a perturbed gateway window IS detected as different"; fi

# The structural claim: zero deleted lines in dispatch.sh.
DEL="$(git -C "$KIT_ROOT" diff --numstat 39fd66c..HEAD -- files/model-router/scripts/dispatch.sh | awk '{print $2}')"
eq "dispatch.sh has ZERO deleted lines vs the branch base" "${DEL:-none}" "0"
# and the gateway window still comes from the catalog, not the estimate
hasnt "gateway launch text mentions no estimate" \
  "$(emit "$DISPATCH" build_claude_gateway_command "${G[@]}")" "estimate"
has "gateway launch text still carries the catalog window" \
  "$(emit "$DISPATCH" build_claude_gateway_command "${G[@]}")" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536"
summary
