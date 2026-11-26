package router

import (
	"fmt"
	"math"
	"time"
)

// Plan pacing: a flat-rate window that resets with quota left is quota
// paid for and lost, and one that runs dry before its reset stops work.
// From a measured reading (how much of the window is used, and when it
// resets) AFK projects where the window ends at the rate so far, says so,
// and, with route.pacing on, leans the routing toward quota that is about
// to go unused and away from a plan that will run out first.

// Pacing is one pool's projection.
type Pacing struct {
	// Window is the window the reading is for: "5h" or "weekly".
	Window string `json:"window"`
	// ResetsAt is when that window resets.
	ResetsAt string `json:"resets_at"`
	// ElapsedPct is how far through the window we are.
	ElapsedPct float64 `json:"elapsed_pct"`
	// UnusedAtResetPct is the share of the window projected to be left
	// over at the reset, when the pace so far won't use it all.
	UnusedAtResetPct *float64 `json:"unused_at_reset_pct,omitempty"`
	// RunsOutAt is when the window is projected to run dry, when that is
	// before the reset.
	RunsOutAt *string `json:"runs_out_at,omitempty"`
	// Adjustment is the points route.pacing adds to routes on this pool.
	Adjustment float64 `json:"adjustment"`
}

// Window lengths AFK knows.
var windowLength = map[string]time.Duration{
	"5h":     5 * time.Hour,
	"weekly": 7 * 24 * time.Hour,
}

// paceMinElapsed is how far into a window a projection starts: before
// that, one run is most of the evidence.
const paceMinElapsed = 0.10

// PaceMaxAdjustment is the most pacing moves a route's score, either way.
const PaceMaxAdjustment = 4.0

// measuredSources are the quota sources a pace can be projected from.
var measuredSources = map[string]bool{
	"codex_rate_limits":       true,
	"claude_rate_limit_event": true,
}

// pace projects a pool's window, or returns nil when its figures are not
// a measurement with a known window and reset.
func pace(p Pool, now time.Time) *Pacing {
	if !measuredSources[p.QuotaSource] || p.UsedPct == nil || p.ResetsAt == nil {
		return nil
	}
	length, ok := windowLength[poolWindow(p)]
	if !ok {
		return nil
	}
	reset, err := time.Parse(time.RFC3339, *p.ResetsAt)
	if err != nil {
		return nil
	}
	left := reset.Sub(now)
	if left <= 0 || left > length {
		return nil
	}
	elapsed := 1 - float64(left)/float64(length)
	out := &Pacing{Window: poolWindow(p), ResetsAt: *p.ResetsAt, ElapsedPct: math.Round(elapsed * 100)}
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

// PaceText is the pacing line for people, in loc:
// "weekly window resets in 9h with ~58% unused at this rate".
func PaceText(pc *Pacing, now time.Time, loc *time.Location) string {
	if pc == nil {
		return ""
	}
	reset, err := time.Parse(time.RFC3339, pc.ResetsAt)
	if err != nil {
		return ""
	}
	in := "resets in " + span(reset.Sub(now))
	switch {
	case pc.UnusedAtResetPct != nil:
		return fmt.Sprintf("%s window %s with ~%.0f%% unused at this rate", pc.Window, in, *pc.UnusedAtResetPct)
	case pc.RunsOutAt != nil:
		if t, err := time.Parse(time.RFC3339, *pc.RunsOutAt); err == nil {
			when := t.In(loc).Format("15:04")
			if t.Sub(now) > 20*time.Hour {
				when = t.In(loc).Format("Mon 15:04")
			}
			return fmt.Sprintf("%s window runs out %s at this rate, before it %s", pc.Window, when, in)
		}
	}
	if pc.ElapsedPct < paceMinElapsed*100 {
		return fmt.Sprintf("%s window %s (too early to project)", pc.Window, in)
	}
	return fmt.Sprintf("%s window %s, on pace", pc.Window, in)
}

// span is a duration in the largest whole unit that reads well: 40m, 9h,
// 3d 4h.
func span(d time.Duration) string {
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(math.Max(1, math.Round(d.Minutes()))))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(math.Round(d.Hours())))
	}
	days := int(d.Hours()) / 24
	if h := int(d.Hours()) % 24; h > 0 {
		return fmt.Sprintf("%dd %dh", days, h)
	}
	return fmt.Sprintf("%dd", days)
}
