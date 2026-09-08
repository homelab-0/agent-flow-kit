#!/usr/bin/env bash
# fixtures2.sh — verbatim slices of tests/run-tests.sh helper defs.
BUDGET_POLICY_SHIPPED="$KIT_ROOT/files/model-router/context-budget-policy.yaml"
bud() { jq -r "$1" "$2"; }               # read one budget field from a result
reset_stubs() {                          # forget what the last case did
  : > "$STUB_STATE/curl-calls"; : > "$STUB_STATE/terminal-creates"
  rm -f "$STUB_STATE/last-command.txt"
}
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"

spawn_reset() { unset STUB_SPAWN_PATH1 STUB_SPAWN_BODY1 STUB_SPAWN_PATH2 STUB_SPAWN_BODY2; }
ckpt() { # <schema> [extra members json]
  local x="${2:-}"; [[ -n "$x" ]] || x='{}'
  jq -nc --arg s "$1" --argjson x "$x" \
    '{schema:$s, completed:["one"], current_state:"mid", remaining_acceptance:["AC-9"],
      next_steps:["resume"], updated_at:"2026-09-07T00:00:00Z"} + $x'
}
CONT_EXTRA='{"in_flight":"the gate run","unretired_findings":[]}'
CAP="$(yq -r '.continuation_cap' "$BUDGET_POLICY_SHIPPED")"
CONT_BODY="$(ckpt afk-continuation/1 "$CONT_EXTRA")"

# retain — synthesise ONE retained per-cycle thin result, which is the only
# evidence the chain and the cap are counted from.
retain() { # <story-basename> <cycle> <continuation_of-json|null>
  jq -n --arg s "$1.md" --argjson c "$2" --argjson cof "$3" \
    '{story:$s, cycle:$c, status:"continuation_required",
      budget:{state:"CONTINUATION_REQUIRED", usage_tokens:180000, usage_ratio:0.900000,
              continuation_artifact:(if $cof == null
                                     then {path:($s+".continuation.json"), sha256:"sha256:seed"}
                                     else null end),
              continuation_of:$cof}}' > "$WT/$1.md.result.c$2.json"
}
cont_story() { # <basename> [extra frontmatter]
  write_story "$WT/$1.md" "persona: dev
gates: [\"true\"]
max_cycles: 8${2:-}"
  write_stamp "$WT/$1.md.stamp.json" high false
  printf '%s' "$CONT_BODY" > "$WT/$1.md.continuation.json"
}
# dflt_story — the SHIPPED defaults: a story that declares no max_cycles at all,
# so the launcher's own default of 3 applies. B1 lived here.
dflt_story() { # <basename> [extra frontmatter]
  write_story "$WT/$1.md" "persona: dev
gates: [\"true\"]${2:-}"
  write_stamp "$WT/$1.md.stamp.json" high false
  printf '%s' "$CONT_BODY" > "$WT/$1.md.continuation.json"
}
# ledger — plant the append-only continuation ledger, one entry per cycle
# listed. The cap is its LENGTH, so what the entries say about cycle numbers is
# deliberately not what is counted.
ledger() { # <story-basename> <cycle>...
  local name="$1"; shift
  local c arr="[]"
  for c in "$@"; do
    arr="$(jq -c --argjson c "$c" \
      '. + [{cycle:$c, from_cycle:($c - 1), artifact_sha256:"sha256:seed",
             trigger:"WORKER_SIGNAL", at:"2026-09-07T00:00:00Z", decision:null}]' <<<"$arr")"
  done
  jq -n --argjson e "$arr" '{schema:"afk-continuation-ledger/1", entries:$e}' \
    > "$WT/$name.md.continuations.json"
}
# marker_frontmatter_block — the CONTINUATION-CAP marker's suggested frontmatter,
# taken verbatim out of the marker and dedented by exactly the indent the marker
# prints it under. Nothing is retyped: what is applied is what a human copies.
marker_frontmatter_block() { # <marker-file>
  sed -n '/^      continuation_decision:$/,/^      max_cycles: /p' "$1" | sed 's/^      //'
}

# --- an ordinary cycle is unaffected, artifact on disk or not -------------
