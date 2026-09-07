#!/usr/bin/env bash
# ATTACK 4 — usage adapters (AC-1) and post-run evaluation (AC-2).
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
source "$ROOT/files/model-router/scripts/dispatch.sh" 2>/dev/null || true
W=${TMP:-/tmp}/rev1.5b/usage; rm -rf "$W"; mkdir -p "$W"
BUDGET_CHECKPOINT_PPM=700000; BUDGET_CONTINUATION_PPM=850000; HARNESS=claude

mk() { printf '%s' "$2" > "$W/$1"; printf '%s' "$W/$1"; }

probe() { # <label> <result-file-or-empty> <model>
  printf '%-46s %s\n' "$1" "$(harness_usage_observation claude "$2" "$3")"
}
echo "=== S1: claude adapter, envelope shapes ==="
probe "normal, model key present" "$(mk a.json '{"usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":5000},"modelUsage":{"claude-opus-5":{"contextWindow":200000}}}')" claude-opus-5
probe "modelUsage EMPTY (zero entries)" "$(mk b.json '{"usage":{"input_tokens":10},"modelUsage":{}}')" claude-opus-5
probe "modelUsage ONE entry, key mismatch" "$(mk c.json '{"usage":{"input_tokens":10},"modelUsage":{"other-model":{"contextWindow":123}}}')" claude-opus-5
probe "modelUsage TWO entries, key mismatch" "$(mk d.json '{"usage":{"input_tokens":10},"modelUsage":{"m1":{"contextWindow":1},"m2":{"contextWindow":2}}}')" claude-opus-5
probe "modelUsage absent entirely" "$(mk e.json '{"usage":{"input_tokens":10}}')" claude-opus-5
probe "no result FILE at all" "$W/does-not-exist.json" claude-opus-5
probe "empty result file" "$(mk f.json '')" claude-opus-5
probe "garbled JSON" "$(mk g.json '{"usage":{')" claude-opus-5
probe "usage present but EMPTY object" "$(mk h.json '{"usage":{}}')" claude-opus-5
probe "usage is a STRING" "$(mk i.json '{"usage":"1000"}')" claude-opus-5
probe "input_tokens is a STRING" "$(mk j.json '{"usage":{"input_tokens":"10"}}')" claude-opus-5
probe "usage is an ARRAY" "$(mk k.json '{"usage":[{"input_tokens":10}]}')" claude-opus-5
probe "top level is an ARRAY (stream log)" "$(mk l.json '[{"usage":{"input_tokens":10}}]')" claude-opus-5
probe "contextWindow is a string" "$(mk m.json '{"usage":{"input_tokens":10},"modelUsage":{"claude-opus-5":{"contextWindow":"200000"}}}')" claude-opus-5
probe "output_tokens ONLY (no input at all)" "$(mk n.json '{"usage":{"output_tokens":9999}}')" claude-opus-5
echo
echo "codex adapter: $(harness_usage_observation codex "$W/a.json" claude-opus-5)"
echo "unknown harness: $(harness_usage_observation gemini "$W/a.json" claude-opus-5)"
echo
echo "=== no scraping: terminal/transcript reads on the usage path ==="
sed -n '/^usage_unobservable/,/^harness_usage_observation()/p;/^budget_evaluate_usage/,/^}/p' "$ROOT/files/model-router/scripts/dispatch.sh" \
  | grep -nE 'TERMINAL_TAIL|orca terminal read|transcript|tail -|buffer' || echo "none (adapters + evaluator read no terminal)"
echo "CONTROL: the same grep DOES find the pre-existing terminal read elsewhere in the file:"
grep -nE 'WORKER_TEXT="\$TERMINAL_TAIL"' "$ROOT/files/model-router/scripts/dispatch.sh"
echo
echo "=== S2/AC-2: thresholds, boundary equality (window 200000; cp 0.70 cont 0.85) ==="
for t in 139999 140000 140001 169999 170000 170001 200000 240000 0; do
  BUDGET_STATE=OK BUDGET_REASON="" BUDGET_FINDINGS=()
  obs="$(jq -nc --argjson t "$t" '{usage_tokens:$t,window_tokens:200000,provenance:"HARNESS_ENVELOPE",observed_at:"END_OF_RUN",reason:null}')"
  budget_evaluate_usage "$obs" 200000 >/dev/null 2>&1
  printf 'usage %-7s ratio %-10s state %-22s findings [%s]\n' "$t" "$BUDGET_USAGE_RATIO" "$BUDGET_STATE" "${BUDGET_FINDINGS[*]-}"
done
echo
echo "=== unobservability must NOT overwrite the pre-dispatch verdict ==="
for pre in OK NOT_EVALUATED; do
  BUDGET_STATE=$pre; BUDGET_REASON=PRE; BUDGET_FINDINGS=()
  budget_evaluate_usage "$(usage_unobservable USAGE_UNOBSERVABLE)" 200000 >/dev/null 2>&1
  printf 'pre=%-14s -> post state=%-14s reason=%-6s usage_reason=%s\n' "$pre" "$BUDGET_STATE" "$BUDGET_REASON" "$BUDGET_USAGE_REASON"
done
echo "no catalog window at all:"
BUDGET_STATE=NOT_EVALUATED; BUDGET_REASON=CONTEXT_WINDOW_UNDECLARED; BUDGET_FINDINGS=()
budget_evaluate_usage "$(jq -nc '{usage_tokens:5,window_tokens:9,provenance:"HARNESS_ENVELOPE",observed_at:"END_OF_RUN",reason:null}')" "" >/dev/null 2>&1
printf '  state=%s reason=%s usage_reason=%s findings=[%s]\n' "$BUDGET_STATE" "$BUDGET_REASON" "$BUDGET_USAGE_REASON" "${BUDGET_FINDINGS[*]-}"
echo
echo "=== window disagreement is recorded, never resolved ==="
BUDGET_STATE=OK BUDGET_FINDINGS=()
budget_evaluate_usage "$(jq -nc '{usage_tokens:1000,window_tokens:1000000,provenance:"HARNESS_ENVELOPE",observed_at:"END_OF_RUN",reason:null}')" 200000 2>&1 | sed 's/^/  log: /'
printf '  findings=[%s] ratio=%s (denominator = CATALOG 200000? %s)\n' "${BUDGET_FINDINGS[*]-}" "$BUDGET_USAGE_RATIO" "$([[ $BUDGET_USAGE_RATIO == 0.005000 ]] && echo yes || echo NO)"
