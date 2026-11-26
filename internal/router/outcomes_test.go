package router

import "testing"

func TestOutcomeAdjustment(t *testing.T) {
	for _, tc := range []struct {
		st       OutcomeStats
		min, max float64
	}{
		{OutcomeStats{Solved: 1}, 0, 0},                // one run doesn't count
		{OutcomeStats{Solved: 5}, 4, 4.5},              // 5/9 * 0.4 * 20
		{OutcomeStats{Wrong: 5}, -6.7, -6.6},           // 5/9 * -0.6 * 20
		{OutcomeStats{Solved: 3, Partly: 2}, 2.2, 2.3}, // rate 0.8
		{OutcomeStats{Solved: 300}, 6, 6},              // capped
		{OutcomeStats{Wrong: 300}, -8, -8},             // capped
	} {
		if a := tc.st.Adjustment(); a < tc.min || a > tc.max {
			t.Errorf("%+v: %v, want %v..%v", tc.st, a, tc.min, tc.max)
		}
	}
}

func TestOutcomeKeyPrefersTheCanonicalModel(t *testing.T) {
	if k := OutcomeKeyFor("claude", "anthropic/claude-opus", "opus", "coding_complex"); k.Model != "anthropic/claude-opus" {
		t.Errorf("key %+v", k)
	}
	if k := OutcomeKeyFor("codex", "", "sol", "coding_standard"); k.Model != "sol" {
		t.Errorf("key %+v", k)
	}
}

func TestRatingsMoveTheScore(t *testing.T) {
	probe := &Probe{Harnesses: map[string]HarnessState{"claude": {Installed: true}, "codex": {Installed: true}}, Pools: map[string]Pool{}}
	r := &Router{Catalog: DefaultCatalog(), Probe: probe}
	in := Input{Stage: "build", Risk: "medium"}
	before := r.Select(in)
	if before.IsFallback() || before.OutcomeAdjustment != nil {
		t.Fatalf("without ratings: %+v", before)
	}
	k := OutcomeKeyFor(before.Harness, before.CanonicalModel, before.Model, before.TaskClass)
	r.Outcomes = map[OutcomeKey]OutcomeStats{k: {Wrong: 20}}
	after := r.Select(Input{Stage: "build", Risk: "medium", OnlyHarnesses: []string{before.Harness}})
	if after.CandidateID == before.CandidateID {
		if after.OutcomeAdjustment == nil || *after.OutcomeAdjustment >= 0 || after.EffectiveScore >= before.EffectiveScore {
			t.Fatalf("20 wrong picks left the score as it was: %+v", after)
		}
		if after.OutcomeRuns == nil || *after.OutcomeRuns != 20 {
			t.Errorf("outcome_runs %v", after.OutcomeRuns)
		}
	}
	// The pick itself moves off the route you keep marking wrong.
	if got := r.Select(in); got.CandidateID == before.CandidateID {
		t.Errorf("still picks %s after 20 wrong picks (score %v)", got.CandidateID, got.EffectiveScore)
	}
}
