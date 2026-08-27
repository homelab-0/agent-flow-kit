#!/usr/bin/env bash
# P2 — "one bounded pass" is still untrue for the monitor's TWO Orca
# observations on a host with no timeout(1), and the fix's new contract sentence
# now asserts that it is true for all three kinds.
#
# WHAT THIS ATTACKS
#
# The cycle-3 fix added `afk_monitor_git_remote` (lib/afk-monitor.sh:373-401),
# which is strict: no bounding tool -> report PROBE_BOUND_UNAVAILABLE and do NOT
# run the call. That closes B4 for the three git calls.
#
# The pass's other two external observations — `orca terminal list`
# (lib/afk-monitor.sh:412) and `orca terminal close --durable` (:445) — still go
# through afk_probe_run (lib/afk-readiness.sh:462-497), which on a host without
# timeout(1) warns and then RUNS THE CALL UNBOUNDED (:476-483). So
# `monitor --cleanup --live` against an Orca that accepts the request and then
# says nothing does not return: the coordinator is stuck inside the pass that was
# settling a worker, which is the exact failure this engine exists to remove.
#
# The delta made this a delta-scoped finding by asserting the opposite:
#
#   docs/LIFECYCLE-CONTRACT.md:650-655 (new in cycle 3)
#     "Every observation the pass makes outside this host is bounded by the same
#      declared timeout the live probes use ... the Orca listing, the durable
#      close, and the remote-branch observations alike. An unbounded call would
#      make 'one bounded pass' untrue of the pass that mattered most."
#
#   docs/LIFECYCLE-CONTRACT.md:645-648 (frozen)
#     "monitor performs exactly one bounded pass per invocation. ... Nothing here
#      blocks, and nothing here can spin."
#
#   docs/LIFECYCLE-CONTRACT.md:421-423 (frozen)
#     "A host that cannot bound a probe reports PROBE_BOUND_UNAVAILABLE rather
#      than running an unbounded probe as if it were a bounded one."
#
# REACHABILITY: a host without coreutils timeout(1) — macOS without coreutils,
# and minimal containers, are the ordinary cases — plus an Orca daemon that
# stalls. afk_require_tools (lib/afk-common.sh:67) does not require timeout, and
# nothing refuses `--live` without it, so the operator gets no warning.
#
# METHOD: run the same fixture three times under a PATH sandbox that differs in
# exactly one entry — whether timeout(1) is reachable.
#
# CONTROLS
#   A — the same stalled Orca WITH timeout(1) on PATH: the pass returns in
#       seconds and fails closed on NEEDS_OWNER. Proves the hang is the missing
#       bound, not the sandbox and not the fixture.
#   B — no timeout(1) on PATH but an Orca that ANSWERS: the pass returns
#       promptly. Proves the sandbox PATH is complete enough to run the kit.
#
# EXIT: 0 REPRODUCED (blocker stands) · 1 NOT REPRODUCED · 2 inconclusive.

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
for need in bash jq git find sed grep awk sort head date mktemp; do
  PATH="$SANDBOX" command -v "$need" >/dev/null 2>&1 || {
    echo "INCONCLUSIVE: sandbox PATH is missing $need"; exit 2; }
done

# The Orca stub. STUB_ORCA_STALL=1 accepts the request and then says nothing for
# two minutes — a dropped VPN, a wedged daemon, a stalled socket. The fixture's
# own sleep caps the damage instead of hanging whoever runs this.
cat > "$SANDBOX/orca" <<'STUB'
#!/usr/bin/env bash
if [[ "${STUB_ORCA_STALL:-0}" == "1" ]]; then
  sleep 120
fi
case "${1:-} ${2:-}" in
  "terminal list")  printf '{"terminals":[{"handle":"term-p2","status":"IDLE"}]}\n'; exit 0 ;;
  "terminal close") printf '{"ok":true,"closed":true,"durable":true}\n'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$SANDBOX/orca"

HOMEDIR=""; STATE=""; WATCH=""; INBOX=""
new_scenario() {
  HOMEDIR="$TMPROOT/sc-$1/home"
  STATE="$HOMEDIR/.local/state/agent-flow-kit"
  WATCH="$STATE/dispatch/watch"; INBOX="$STATE/dispatch/inbox"
  mkdir -p "$HOMEDIR"
}
descriptor() {
  jq -nc '{dispatch_id:"d-p2", task_id:"TASK-P2",
           terminal:{handle:"term-p2", owned:true},
           worktree:{path:"", owned:true},
           branch:{name:"", repo:"", base:"", remote:"", owned:true,
                   disposable:false, pr_merged:false, remote_delete_authorized:false}}'
}
deliver() { # <delivery id> <dispatch id>
  mkdir -p "$INBOX"
  jq -nc --arg d "$1" --arg t "$2" \
    '{schema_version:"1.0", delivery_id:$d, dispatch_id:$t, kind:"worker_done",
      result:{status:"done", summary:"one bounded worker result"}}' > "$INBOX/$1.json"
}
RUN_OUT=""; RUN_RC=0; RUN_ELAPSED=0
run_afk() { # <path-prefix-or-empty> <args...>
  local prefix="$1"; shift
  local p="$SANDBOX" t0 t1
  [[ -n "$prefix" ]] && p="$prefix:$SANDBOX"
  t0="$(date +%s)"
  RUN_OUT="$("$REAL_TIMEOUT" 45 env PATH="$p" HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             STUB_ORCA_STALL="${STUB_ORCA_STALL:-0}" \
             "$SANDBOX/bash" "$AFK" "$@" </dev/null 2>/dev/null)"
  RUN_RC=$?
  t1="$(date +%s)"
  RUN_ELAPSED=$(( t1 - t0 ))
}
rec() { jq -r "$2" "$WATCH/$1.json" 2>/dev/null; }
say() { printf '%s\n' "$*"; }

setup_scenario() { # <name> — register the Dispatch and commit one delivery
  new_scenario "$1"
  descriptor > "$TMPROOT/descriptor.json"
  STUB_ORCA_STALL=0 run_afk "$WITHTO" monitor --json --register "$TMPROOT/descriptor.json"
  [[ "$RUN_RC" == "0" ]] || { say "INCONCLUSIVE: register failed rc=$RUN_RC"; exit 2; }
  deliver del-p2 d-p2
}

# ===========================================================================
say "== CONTROL A: stalled Orca, timeout(1) ON PATH ==========================="
# ===========================================================================
setup_scenario ctrl-a
export STUB_ORCA_STALL=1
run_afk "$WITHTO" monitor --json --cleanup --live
CA_RC="$RUN_RC"; CA_EL="$RUN_ELAPSED"; CA_TERM="$(rec d-p2 '.cleanup.terminal')"
say "  elapsed = ${CA_EL}s  (predicted: well under 45 — the probe bound is ~5s)"
say "  exit    = $CA_RC     (predicted: 2, not 124)"
say "  cleanup.terminal = $CA_TERM (predicted: NEEDS_OWNER — the listing could not be read)"
CONTROL_A_OK=0
[[ "$CA_RC" != "124" && "$CA_EL" -lt 45 ]] && CONTROL_A_OK=1

# ===========================================================================
say ""
say "== CONTROL B: answering Orca, timeout(1) NOT on PATH ====================="
# ===========================================================================
setup_scenario ctrl-b
export STUB_ORCA_STALL=0
run_afk "" monitor --json --cleanup --live
CB_RC="$RUN_RC"; CB_EL="$RUN_ELAPSED"
say "  elapsed = ${CB_EL}s  (predicted: seconds — the sandbox PATH runs the kit fine)"
say "  exit    = $CB_RC     (predicted: 0 or 2, never 124)"
CONTROL_B_OK=0
[[ "$CB_RC" != "124" && "$CB_EL" -lt 45 ]] && CONTROL_B_OK=1

# ===========================================================================
say ""
say "== ATTACK: stalled Orca, timeout(1) NOT on PATH =========================="
# ===========================================================================
setup_scenario attack
export STUB_ORCA_STALL=1
run_afk "" monitor --json --cleanup --live
A_RC="$RUN_RC"; A_EL="$RUN_ELAPSED"
say "  elapsed = ${A_EL}s  (predicted: 45 — the OUTER bound, because the pass has none)"
say "  exit    = $A_RC     (predicted: 124, killed by the external timeout)"
REPRODUCED=0
[[ "$A_RC" == "124" ]] && REPRODUCED=1

# ===========================================================================
say ""
if (( CONTROL_A_OK == 0 || CONTROL_B_OK == 0 )); then
  say "VERDICT: INCONCLUSIVE — a control did not behave as predicted"
  say "         (A ok=$CONTROL_A_OK, B ok=$CONTROL_B_OK), so the fixture cannot"
  say "         support a claim either way."
  exit 2
fi
if (( REPRODUCED == 1 )); then
  say "VERDICT: REPRODUCED — with no timeout(1) on PATH the monitor's Orca"
  say "         observations run unbounded and the settlement pass does not"
  say "         return. Both controls hold, so the only variable is the bound."
  say "         docs/LIFECYCLE-CONTRACT.md:650-655 asserts the opposite."
  exit 0
fi
say "VERDICT: NOT REPRODUCED — the pass returned on its own without a bounding"
say "         tool on PATH."
exit 1
