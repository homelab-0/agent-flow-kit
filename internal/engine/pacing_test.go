package engine

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"
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
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("route changed: %s", out)
	}
}

func TestReadAgo(t *testing.T) {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)
	at := func(d time.Duration) string { return now.Add(-d).Format(time.RFC3339) }
	for _, c := range []struct{ in, want string }{
		{"", ""},
		{"not a time", ""},
		{at(5 * time.Minute), ""}, // fresh: nothing to add
		{at(25 * time.Minute), "25m ago"},
		{at(3*time.Hour + 10*time.Minute), "3h ago"},
		{at(72 * time.Hour), "3d ago"},
	} {
		if got := (Pool{ObservedAt: c.in}).ReadAgo(now); got != c.want {
			t.Errorf("ReadAgo(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
