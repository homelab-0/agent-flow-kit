package router

import (
	"math"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// Plan pacing: a flat-rate window that resets with quota left is quota
// paid for and lost, and one that runs dry before its reset stops work.
// From a measured reading (how much of the window is used, and when it
// resets) AFK projects where the window ends at the rate so far, says so,
// and, with route.pacing on, leans the routing toward quota that is about
// to go unused and away from a plan that will run out first.

// Pacing is one pool's projection. It is engine's type, so the front end
// reads the same document the router writes.
type Pacing = engine.Pacing

// Window lengths AFK knows.
var windowLength = map[string]time.Duration{
	"5h":     5 * time.Hour,
	"weekly": 7 * 24 * time.Hour,
}

// paceMinElapsed is how far into a window a projection starts.
const paceMinElapsed = engine.PaceMinElapsed

// PaceMaxAdjustment is the most pacing moves a route's score, either way.
const PaceMaxAdjustment = 4.0

// measuredSources are the quota sources a pace can be projected from.
var measuredSources = map[string]bool{
	"codex_rate_limits":       true,
	"codex_app_server":        true,
	"claude_rate_limit_event": true,
}

// pace projects a pool's window, or returns nil when its figures are not
// a measurement with a known window and reset.
//
// The projection is from when the reading was taken: a reading reused on
// later probes keeps the same used share, so measuring the elapsed share
// at the probe would drift it toward "unused" as time passed.
func pace(p Pool, now time.Time) *Pacing {
	if !measuredSources[p.QuotaSource] || p.UsedPct == nil || p.ResetsAt == nil {
		return nil
	}
	length, ok := windowLength[poolWindow(p)]
	if !ok {
		return nil
	}
	reset, err := time.Parse(time.RFC3339, *p.ResetsAt)
	if err != nil || !reset.After(now) {
		return nil
	}
	at := now
	if !p.observed.IsZero() && p.observed.Before(now) {
		at = p.observed
	}
	left := reset.Sub(at)
	if left <= 0 || left > length {
		return nil
	}
	elapsed := 1 - float64(left)/float64(length)
	out := &Pacing{Window: poolWindow(p), ResetsAt: *p.ResetsAt, ElapsedPct: math.Round(elapsed * 100)}
	now = at // the projection below is as of the reading
	if elapsed < paceMinElapsed {
		return out
	}
	used := math.Max(0, math.Min(100, *p.UsedPct))
	if used >= 100 {
		return out // spent: the pool state already says so
	}
	projected := used / elapsed
	switch {
	case projected < 100:
		unused := math.Round(100 - projected)
		out.UnusedAtResetPct = &unused
		// Lean toward it, more as the reset nears and the more would be
		// lost: full weight at half the window unused.
		out.Adjustment = PaceMaxAdjustment * math.Min(1, unused/50) * elapsed
	case projected > 100:
		rate := used / elapsed // percent of the window per window
		dry := now.Add(time.Duration((100 - used) / rate * float64(length)))
		if dry.Before(reset) {
			s := dry.UTC().Format(time.RFC3339)
			out.RunsOutAt = &s
			// Lean away, more the longer the plan would sit empty.
			short := float64(reset.Sub(dry)) / float64(length)
			out.Adjustment = -PaceMaxAdjustment * math.Min(1, short*2)
		}
	}
	out.Adjustment = math.Round(out.Adjustment*10) / 10
	return out
}

// poolWindow is the window a pool's figure is for, as engine.Pool.Window
// names it.
func poolWindow(p Pool) string {
	if p.Window != "" {
		return p.Window
	}
	switch {
	case p.WeeklyUsedPct == nil:
		return "5h"
	case p.FiveHourUsedPct == nil || *p.WeeklyUsedPct > *p.FiveHourUsedPct:
		return "weekly"
	}
	return "5h"
}

// PaceText is the pacing line for people, in loc.
func PaceText(pc *Pacing, now time.Time, loc *time.Location) string {
	return engine.PaceText(pc, now, loc)
}
