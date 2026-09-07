#!/usr/bin/env bash
# Attack 3 — the launch-class discriminator, exhaustively. Enumerates the whole
# cross product the guard can be handed and prints ADMIT/REFUSE for each, then
# asserts the expected set. Control: the enumeration must produce at least one
# ADMIT and many REFUSEs, so a guard that refused everything (or admitted
# everything) could not pass silently.
set -uo pipefail
WT="$(git rev-parse --show-toplevel)"
. "$WT/files/model-router/scripts/dispatch.sh"
set +e

fail=0
adm=0; ref=0
verdict() { # harness profile placement pool hosting cost -> ADMIT|REFUSE
  local r; r="$(unsupported_launch_reason "$@")"
  if [[ -z "$r" ]]; then echo ADMIT; else echo REFUSE; fi
}
expect() { # <expected> <label> <args...>
  local want="$1" label="$2"; shift 2
  local got; got="$(verdict "$@")"
  [[ "$got" == ADMIT ]] && ((adm++)) || ((ref++))
  if [[ "$got" == "$want" ]]; then printf 'PASS %-62s %s\n' "$label" "$got"
  else printf 'FAIL %-62s got %s want %s\n' "$label" "$got" "$want"; fail=1; fi
}

echo "== native class 1 (must be exactly as on master)"
expect ADMIT  "claude claude/strong anthropic-max vendor-hosted"   claude claude/strong false anthropic-max '' subscription
expect ADMIT  "codex  openai/strong openai-plus vendor-hosted"     codex  openai/strong false openai-plus  '' subscription
expect REFUSE "claude claude/strong on the WRONG pool"             claude claude/strong false minimax-max  '' subscription
expect REFUSE "claude minimax/strong on minimax-max"               claude minimax/strong false minimax-max '' subscription
expect REFUSE "codex  claude/strong on anthropic-max"              codex  claude/strong false anthropic-max '' subscription
expect REFUSE "claude claude/strong native pool but placement TRUE" claude claude/strong true anthropic-max '' subscription

echo "== class 2 admit — every condition present"
expect ADMIT  "claude local hosting=local pool='' cost=free"       claude local-code-standard true ''   local free
expect ADMIT  "claude local pool literal 'null' cost=free"         claude local-code-standard true null local free

echo "== class 2 — drop exactly one condition at a time"
expect REFUSE "  harness codex instead of claude"                  codex  local-code-standard true ''   local free
expect REFUSE "  hosting missing (unset)"                          claude local-code-standard true ''   ''    free
expect REFUSE "  hosting vendor"                                   claude local-code-standard true ''   vendor free
expect REFUSE "  hosting 'Local' (case)"                           claude local-code-standard true ''   Local free
expect REFUSE "  entitlement pool present"                         claude local-code-standard true anthropic-max local free
expect REFUSE "  cost_class subscription"                          claude local-code-standard true ''   local subscription
expect REFUSE "  cost_class unset"                                 claude local-code-standard true ''   local ''
expect REFUSE "  cost_class 'Free' (case)"                         claude local-code-standard true ''   local Free
expect REFUSE "  placement_required false (falls to class 1 test)" claude local-code-standard false ''  local free

echo "== un-updated callers: the new args simply absent (must fail CLOSED)"
expect REFUSE "  4-arg call, claude+local"                         claude local-code-standard true ''
expect REFUSE "  5-arg call (hosting only), claude+local"          claude local-code-standard true ''   local
# A 3-arg call cannot reach a verdict at all: $4 has been mandatory since
# master, and under dispatch.sh's own `set -u` an unbound $4 aborts the whole
# script. That is fail-closed by crash, not by refusal, so it is reported as a
# NOTE rather than scored. (There is exactly one call site, and it passes 6.)
printf 'NOTE   3-arg call aborts on unbound $4 under set -u (fail-closed by crash)\n'
( set -u; unsupported_launch_reason claude local-code-standard true >/dev/null 2>&1 ) \
  && printf 'FAIL   ...but it did not abort\n' || printf 'PASS   ...confirmed non-zero\n' 

echo "== unknown / hostile harness"
# UNCHANGED FROM master: the guard declares capability only for the harnesses
# it implements and returns NO reason for an unknown one; main()'s launch `case`
# is what refuses it (`no frozen launch contract for harness ...`), before any
# terminal exists. Scored as ADMIT here because that is literally what the guard
# returns; the refusal is asserted in the readiness mirror below and by main().
expect ADMIT  "  unknown harness: guard abstains (main's case refuses it)"  banana local-code-standard true ''   local free
expect ADMIT  "  empty harness: guard abstains (main's case refuses it)"    ''     local-code-standard true ''   local free

echo "== a VENDOR-hosted profile that (wrongly) requires placement"
expect REFUSE "  claude claude/strong hosting=vendor placement=true free/unpooled" \
   claude claude/strong true '' vendor free
echo "   ^ note: readiness's mirror cannot see hosting; see the readiness probe below"

echo "== refusal wording still carries the strings the suites pin"
for t in "explicitly forbids" "placement_required=true"; do
  if grep -q -- "$t" <<<"$(unsupported_launch_reason codex local-code-standard true '' local free)"; then
    printf 'PASS codex refusal still contains %s\n' "\"$t\""
  else printf 'FAIL codex refusal lost %s\n' "\"$t\""; fail=1; fi
done
r="$(unsupported_launch_reason claude local-code-standard true '' vendor free)"
grep -q "explicitly forbids" <<<"$r" && echo "PASS claude class-2 miss keeps 'explicitly forbids'" || { echo "FAIL"; fail=1; }
grep -q "hosting: local" <<<"$r"     && echo "PASS claude class-2 miss names the catalog fact"     || { echo "FAIL"; fail=1; }
echo "   claude class-2-miss reason: $r"

echo "== CONTROL: the enumeration saw both outcomes"
printf '   ADMIT=%s REFUSE=%s\n' "$adm" "$ref"
{ (( adm >= 2 )) && (( ref >= 14 )); } && echo "PASS control: the guard is discriminating, not constant" \
  || { echo "FAIL control: the guard looks constant"; fail=1; }

echo "== READINESS MIRROR (lib/afk-readiness.sh) on the same rows"
. "$WT/lib/afk-readiness.sh" >/dev/null 2>&1
AFK_APPROVED_HARNESSES="${AFK_APPROVED_HARNESSES:-claude codex}"
mrow() { local r; r="$(afk_launch_contract_reason "$@")"; [[ -z "$r" ]] && echo ADMIT || echo REFUSE; }
printf '   readiness: claude local placement=true pool="" cost=free      -> %s\n' "$(mrow claude local-code-standard true '' free)"
printf '   readiness: claude VENDOR-hosted placement=true pool="" free   -> %s   (adapter: REFUSE)\n' "$(mrow claude claude/strong true '' free)"
printf '   readiness: codex  local placement=true pool="" cost=free      -> %s\n' "$(mrow codex local-code-standard true '' free)"
printf '   readiness: claude local placement=true pool=anthropic-max     -> %s\n' "$(mrow claude local-code-standard true anthropic-max free)"
printf '   readiness: claude local placement=true cost=subscription      -> %s\n' "$(mrow claude local-code-standard true '' subscription)"
if [[ "$(mrow claude claude/strong true '' free)" == ADMIT \
   && "$(verdict claude claude/strong true '' vendor free)" == REFUSE ]]; then
  echo "NOTE readiness ADMITS a row the adapter REFUSES (disclosed residual 5, reproduced)"
fi
exit $fail
