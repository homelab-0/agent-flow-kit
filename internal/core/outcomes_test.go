package core

import (
	"context"
	"testing"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
	"github.com/jlengelbrecht/agent-flow-kit/internal/runrec"
)

func rated(h, model, tc, outcome string, pinned bool) runrec.Record {
	r := runrec.Record{Schema: runrec.Schema, Route: engine.Route{Harness: h, Model: model, TaskClass: tc, Pinned: pinned}}
	if outcome != "" {
		r.Outcome = &outcome
	}
	return r
}

func TestOutcomesTally(t *testing.T) {
	recs := []runrec.Record{
		rated("codex", "sol", "coding_standard", runrec.Solved, false),
		rated("codex", "sol", "coding_standard", runrec.Partly, false),
		rated("codex", "sol", "coding_standard", runrec.WrongPick, false),
		rated("codex", "sol", "coding_standard", "", false),              // unrated
		rated("codex", "sol", "", runrec.Solved, false),                  // no task class
		rated("codex", "sol", "coding_standard", runrec.WrongPick, true), // you pinned it
	}
	got := Outcomes(recs)
	k := router.OutcomeKeyFor("codex", "", "sol", "coding_standard")
	if st := got[k]; st != (router.OutcomeStats{Solved: 1, Partly: 1, Wrong: 1}) || len(got) != 1 {
		t.Fatalf("tally %+v", got)
	}
	var many []runrec.Record
	for i := 0; i < OutcomesPerRoute+10; i++ {
		many = append(many, rated("claude", "opus", "coding_complex", runrec.Solved, false))
	}
	if n := Outcomes(many)[router.OutcomeKeyFor("claude", "", "opus", "coding_complex")].Runs(); n != OutcomesPerRoute {
		t.Errorf("kept %d ratings, want the newest %d", n, OutcomesPerRoute)
	}
}

func TestLoadReadsRatingsUnlessLearningIsOff(t *testing.T) {
	c, _, _ := printCore(t, func([]string) ([]byte, []byte, int) { return nil, nil, 0 })
	dir := runrec.DirFor(c.Home, c.getenv)
	rec := rated("codex", "sol", "coding_standard", runrec.Solved, false)
	rec.ID, rec.EndedAt = "r-ab12", runrec.Stamp(time.Now())
	if _, err := runrec.Write(dir, rec); err != nil {
		t.Fatal(err)
	}
	st, err := c.load(context.Background(), c.Home)
	if err != nil {
		t.Fatal(err)
	}
	if st.r.Outcomes[router.OutcomeKeyFor("codex", "", "sol", "coding_standard")].Solved != 1 {
		t.Fatalf("outcomes %+v", st.r.Outcomes)
	}
	get := c.Getenv
	c.Getenv = func(k string) string {
		if k == "AFK_ROUTER_LEARN" {
			return "0"
		}
		return get(k)
	}
	st, err = c.load(context.Background(), c.Home)
	if err != nil {
		t.Fatal(err)
	}
	if st.r.Outcomes != nil {
		t.Errorf("learning is off, yet outcomes were read: %+v", st.r.Outcomes)
	}
}
