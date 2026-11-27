package core

import (
	"context"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

func TestExplainReportsProgress(t *testing.T) {
	c, _ := testCore(t)
	var got []engine.Progress
	ctx := engine.WithProgress(context.Background(), func(p engine.Progress) { got = append(got, p) })
	ex, err := c.Explain(ctx, engine.RouteFlags{}, "fix the failing test")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) == 0 || got[0].Kind != "start" || len(got[0].Harnesses) == 0 || got[0].Task != ex.Task {
		t.Fatalf("first step should start with the candidates: %+v", got)
	}
	routed := map[string]bool{}
	for _, p := range got[1:] {
		switch p.Kind {
		case "route":
			if p.Route == nil || p.Route.Harness != p.Harness || p.Route.Model == "" {
				t.Errorf("route step without its route: %+v", p)
			}
			routed[p.Harness] = true
		case "skip":
		default:
			t.Errorf("unexpected step %q", p.Kind)
		}
	}
	for _, r := range ex.ByHarness {
		if !routed[r.Harness] {
			t.Errorf("%s is in the payload but was never reported", r.Harness)
		}
	}
}
