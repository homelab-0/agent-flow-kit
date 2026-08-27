#!/usr/bin/env bash
# R1 — evidence for a REGISTERED NON-BLOCKING item, not a blocker claim.
#
# WHAT THIS SHOWS
#
# Cycle 4 closed P2 for the monitor: the Orca listing and the durable close now
# go through afk_monitor_probe_strict (lib/afk-monitor.sh:390-397), which
# refuses rather than running unbounded. The readiness probes were deliberately
# left alone — AFK-PORT-1.3-FIX2.md puts "afk_probe_run's default warn-and-run
# behavior for readiness probes" out of scope — so afk_probe_run
# (lib/afk-readiness.sh:472-484) still warns once and then RUNS THE CALL
# UNBOUNDED on a host with no timeout(1).
#
# That leaves one frozen sentence untrue of the kit:
#
#   docs/LIFECYCLE-CONTRACT.md:421-423 (frozen)
#     "A host that cannot bound a probe reports PROBE_BOUND_UNAVAILABLE rather
#      than running an unbounded probe as if it were a bounded one."
#
# and it makes one sentence the cycle-4 delta ADDED misleading:
#
#   docs/LIFECYCLE-CONTRACT.md:658-659 (new in cycle 4)
#     "This is stricter than the live probes, whose own reading of a missing
#      bound is stated above"
#
# — the document does not state a warn-and-run reading anywhere; what is stated
# above is the strict rule the readiness probes do not follow.
#
# This script exists so the coordinator can rule on that with a run rather than
# on a reading. It attacks `status --live`, NOT the monitor: the monitor's half
# is fixed and P2-orca-observation-unbounded.sh is the script for it.
#
# REACHABILITY: a host without coreutils timeout(1) — macOS without coreutils,
# minimal containers — plus an Orca daemon that accepts the connection and then
# says nothing. `agent-flow-kit status --live` is an ordinary operator command.
#
# METHOD: the same fixture three times under a PATH sandbox that differs in
# exactly one entry — whether timeout(1) is reachable. Only ONE external
# dependency is ever invoked: the orca stub. The validator and both harness
# binaries are pointed at paths that do not exist and the router endpoint is
# cleared, so this script never runs the operator's real claude, codex,
# agent-stamp-validate or curl, and opens no socket.
#
# CONTROLS
#   A — the same stalled Orca WITH timeout(1) on PATH: the run returns in
#       seconds. Proves the stall is bounded when a bound exists, so the attack
#       result is the missing bound and not the sandbox or the stub.
#   B — no timeout(1) on PATH but an Orca that ANSWERS: the run returns
#       promptly. Proves the sandbox PATH is complete enough to run the kit.
#
# EXIT: 0 CONFIRMED (the readiness half is still unbounded)
#       1 NOT CONFIRMED (it returned on its own)
#       2 inconclusive (a control misbehaved, or the fixture could not be built)

set -uo pipefail

KIT_ROOT="${KIT_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
AFK="$KIT_ROOT/bin/agent-flow-kit"
[[ -f "$AFK" ]] || { echo "INCONCLUSIVE: no bin/agent-flow-kit under $KIT_ROOT"; exit 2; }
REAL_TIMEOUT="$(command -v timeout || true)"
[[ -n "$REAL_TIMEOUT" ]] || { echo "INCONCLUSIVE: this host has no timeout(1), so neither the outer bound nor control A can be built"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "INCONCLUSIVE: jq is required"; exit 2; }

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/nobin"      # every PATH executable EXCEPT timeout
WITHTO="$TMPROOT/withtimeout" # one entry: timeout
CHECKOUT="$TMPROOT/checkout"
mkdir -p "$SANDBOX" "$WITHTO" "$CHECKOUT"

# Mirror the real PATH minus timeout(1). Symlinks, so nothing is copied and the
# tools are the host's own.
IFS=':' read -r -a PATH_DIRS <<< "$PATH"
for d in "${PATH_DIRS[@]}"; do
  [[ -n "$d" && -d "$d" ]] || continue
  for f in "$d"/*; do
    [[ -e "$f" ]] || continue
    b="${f##*/}"
    [[ "$b" == "timeout" ]] && continue
    [[ -e "$SANDBOX/$b" ]] && continue
    ln -s "$f" "$SANDBOX/$b" 2>/dev/null || true
  done
done
ln -s "$REAL_TIMEOUT" "$WITHTO/timeout"

if PATH="$SANDBOX" command -v timeout >/dev/null 2>&1; then
  echo "INCONCLUSIVE: the sandbox PATH still resolves timeout(1)"; exit 2
fi
# Everything afk_require_tools (lib/afk-common.sh:67) needs, so a gap in the
# mirror becomes an inconclusive verdict rather than a false one.
for need in bash jq git find sed grep awk wc tr sort readlink head tail cat cp mv date mktemp; do
  PATH="$SANDBOX" command -v "$need" >/dev/null 2>&1 || {
    echo "INCONCLUSIVE: sandbox PATH is missing $need"; exit 2; }
done
if ! PATH="$SANDBOX" command -v sha256sum >/dev/null 2>&1 \
   && ! PATH="$SANDBOX" command -v shasum >/dev/null 2>&1; then
  echo "INCONCLUSIVE: sandbox PATH has neither sha256sum nor shasum"; exit 2
fi

# The Orca stub. STUB_ORCA_STALL=1 accepts the request and then says nothing for
# two minutes — a dropped VPN, a wedged daemon, a stalled socket. The fixture's
# own sleep caps the damage instead of hanging whoever runs this.
cat > "$SANDBOX/orca" <<'STUB'
#!/usr/bin/env bash
if [[ "${STUB_ORCA_STALL:-0}" == "1" ]]; then
  sleep 120
fi
case "${1:-} ${2:-}" in
  "status --json"|"status ")
    printf '{"ok":true,"state":"running"}\n'; exit 0 ;;
  "capabilities --json"|"capabilities ")
    printf '{"capabilities":["worktree-ownership","visible-worker-launch","argument-environment-transport","provider-runtime","session-process-isolation"]}\n'
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$SANDBOX/orca"

HOMEDIR="$TMPROOT/home"
mkdir -p "$HOMEDIR"

RUN_OUT=""; RUN_RC=0; RUN_ELAPSED=0
run_afk() { # <path-prefix-or-empty> <args...>
  local prefix="$1"; shift
  local p="$SANDBOX" t0 t1
  [[ -n "$prefix" ]] && p="$prefix:$SANDBOX"
  t0="$(date +%s)"
  RUN_OUT="$("$REAL_TIMEOUT" 45 env PATH="$p" HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             AFK_VALIDATOR_BIN="$TMPROOT/no-such-validator" \
             AFK_CLAUDE_BIN="$TMPROOT/no-such-claude" \
             AFK_CODEX_BIN="$TMPROOT/no-such-codex" \
             AFK_CURL_BIN="$TMPROOT/no-such-curl" \
             AGENT_ROUTER_URL="" \
             STUB_ORCA_STALL="${STUB_ORCA_STALL:-0}" \
             "$BASH" "$AFK" "$@" </dev/null 2>/dev/null)"
  RUN_RC=$?
  t1="$(date +%s)"
  RUN_ELAPSED=$(( t1 - t0 ))
}
say() { printf '%s\n' "$*"; }

# ===========================================================================
say "== CONTROL A: stalled Orca, timeout(1) ON PATH ==========================="
# ===========================================================================
export STUB_ORCA_STALL=1
run_afk "$WITHTO" status --json --live
CA_RC="$RUN_RC"; CA_EL="$RUN_ELAPSED"
say "  elapsed = ${CA_EL}s  (predicted: seconds — the probe bound is ~5s)"
say "  exit    = $CA_RC     (predicted: anything except 124)"
CONTROL_A_OK=0
[[ "$CA_RC" != "124" && "$CA_EL" -lt 45 ]] && CONTROL_A_OK=1

# ===========================================================================
say ""
say "== CONTROL B: answering Orca, timeout(1) NOT on PATH ====================="
# ===========================================================================
export STUB_ORCA_STALL=0
run_afk "" status --json --live
CB_RC="$RUN_RC"; CB_EL="$RUN_ELAPSED"
CB_BOUND="$(printf '%s' "$RUN_OUT" | jq -r \
  '[.findings[]? | select(.reason == "PROBE_BOUND_UNAVAILABLE")] | length' 2>/dev/null)"
say "  elapsed = ${CB_EL}s  (predicted: seconds — the sandbox PATH runs the kit fine)"
say "  exit    = $CB_RC     (predicted: anything except 124)"
say "  PROBE_BOUND_UNAVAILABLE findings = ${CB_BOUND:-?} (predicted: 1 — it reports, and then runs anyway)"
CONTROL_B_OK=0
[[ "$CB_RC" != "124" && "$CB_EL" -lt 45 ]] && CONTROL_B_OK=1

# ===========================================================================
say ""
say "== ATTACK: stalled Orca, timeout(1) NOT on PATH =========================="
# ===========================================================================
export STUB_ORCA_STALL=1
run_afk "" status --json --live
A_RC="$RUN_RC"; A_EL="$RUN_ELAPSED"
say "  elapsed = ${A_EL}s  (predicted: 45 — the OUTER bound, because the probe has none)"
say "  exit    = $A_RC     (predicted: 124, killed by the external timeout)"
CONFIRMED=0
[[ "$A_RC" == "124" ]] && CONFIRMED=1

# ===========================================================================
say ""
if (( CONTROL_A_OK == 0 || CONTROL_B_OK == 0 )); then
  say "VERDICT: INCONCLUSIVE — a control did not behave as predicted"
  say "         (A ok=$CONTROL_A_OK, B ok=$CONTROL_B_OK), so the fixture cannot"
  say "         support a claim either way."
  exit 2
fi
if (( CONFIRMED == 1 )); then
  say "VERDICT: CONFIRMED — with no timeout(1) on PATH the READINESS probe runs"
  say "         unbounded and \`status --live\` does not return. Both controls"
  say "         hold, so the only variable is the bound. This is the registered"
  say "         residual F1, not a cycle-4 blocker: the monitor half is fixed"
  say "         and this half was explicitly out of scope for the cycle. It"
  say "         does mean docs/LIFECYCLE-CONTRACT.md:421-423 is still untrue of"
  say "         every readiness probe, and that :658-659 points at a documented"
  say "         divergence the document does not contain."
  exit 0
fi
say "VERDICT: NOT CONFIRMED — the readiness pass returned on its own without a"
say "         bounding tool on PATH. F1 would then be documentation-only."
exit 1
