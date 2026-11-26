package engine

import (
	"encoding/json"
	"testing"
)

// A route's pacing reaches the front end as the router wrote it, and the
// route goes back to the engine unchanged.
func TestRouteCarriesPacing(t *testing.T) {
	in := `{"harness":"codex","pacing":{"window":"weekly","resets_at":"2026-11-26T21:00:00Z","elapsed_pct":95,"unused_at_reset_pct":58,"adjustment":3.8},"pacing_adjustment":3.8}`
	var r Route
	if err := json.Unmarshal([]byte(in), &r); err != nil {
		t.Fatal(err)
	}
	if r.Pacing == nil || r.Pacing.Window != "weekly" || r.Pacing.UnusedAtResetPct == nil || *r.Pacing.UnusedAtResetPct != 58 || r.PacingAdjustment == nil || *r.PacingAdjustment != 3.8 {
		t.Fatalf("pacing not read: %+v %v", r.Pacing, r.PacingAdjustment)
	}
	out, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	var a, b map[string]any
	_ = json.Unmarshal([]byte(in), &a)
	_ = json.Unmarshal(out, &b)
	if len(a) != len(b) {
		t.Fatalf("route changed: %s", out)
	}
}
