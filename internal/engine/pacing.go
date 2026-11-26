package engine

import (
	"fmt"
	"math"
	"time"
)

// Pacing is where a measured plan window is heading at the rate so far:
// the router's projection for one pool, as routes and pools carry it.
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

// PaceMinElapsed is how far into a window a projection starts: before
// that, one run is most of the evidence.
const PaceMinElapsed = 0.10

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
	in := "resets in " + Span(reset.Sub(now))
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
	if pc.ElapsedPct < PaceMinElapsed*100 {
		return fmt.Sprintf("%s window %s (too early to project)", pc.Window, in)
	}
	return fmt.Sprintf("%s window %s, on pace", pc.Window, in)
}

// Span is a duration in the largest whole unit that reads well: 40m, 9h,
// 3d 4h.
func Span(d time.Duration) string {
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
