package router

import "math"

// OutcomeKey is what a rating is about: one CLI running one model on one
// kind of task.
type OutcomeKey struct {
	Harness   string
	Model     string // the canonical model id, or the CLI's model id when none
	TaskClass string
}

// OutcomeStats counts the ratings for one key.
type OutcomeStats struct {
	Solved, Partly, Wrong int
}

// Runs is how many rated runs the stats hold.
func (s OutcomeStats) Runs() int { return s.Solved + s.Partly + s.Wrong }

// Outcome scoring. A route needs MinRatedRuns ratings before they count.
// Their weight grows with the number of runs, n/(n+outcomeShrink), so a
// few lucky runs can't swamp the benchmark. A success rate of
// outcomeNeutral leaves the score as it is; all solved or all wrong moves
// it by up to outcomeMaxUp or outcomeMaxDown points.
const (
	MinRatedRuns   = 2
	outcomeShrink  = 4.0
	outcomeNeutral = 0.6
	outcomeSlope   = 20.0
	outcomeMaxUp   = 6.0
	outcomeMaxDown = 8.0
)

// Adjustment is the points the ratings add to (or take from) a route's
// score: 0 below MinRatedRuns.
func (s OutcomeStats) Adjustment() float64 {
	n := float64(s.Runs())
	if s.Runs() < MinRatedRuns {
		return 0
	}
	rate := (float64(s.Solved) + 0.5*float64(s.Partly)) / n
	adj := n / (n + outcomeShrink) * (rate - outcomeNeutral) * outcomeSlope
	adj = math.Max(-outcomeMaxDown, math.Min(outcomeMaxUp, adj))
	return math.Round(adj*100) / 100
}

// OutcomeKeyFor is the key for a route: the canonical model id when there
// is one, else the CLI's own model id.
func OutcomeKeyFor(harness, canonical, model, taskClass string) OutcomeKey {
	m := canonical
	if m == "" {
		m = model
	}
	return OutcomeKey{Harness: harness, Model: m, TaskClass: taskClass}
}
