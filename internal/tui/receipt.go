package tui

import (
	"fmt"
	"math"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// Receipt is what the session did.
type Receipt struct {
	Route      engine.Route
	ExitCode   int
	Signal     string
	Duration   time.Duration
	PoolBefore *float64
	PoolAfter  *float64
	InRepo     bool
	Files      *int
	Commits    *int
}

func plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}

// ReceiptLine: ✓ claude exited 0 · 23m 41s · pool 78% → 71% · 3 files changed
func (t Theme) ReceiptLine(r Receipt) line {
	mark, st := "  ✓ ", t.OK
	if r.ExitCode != 0 {
		mark, st = "  ! ", t.Warn
	}
	what := fmt.Sprintf("%s exited %d", routeName(r.Route), r.ExitCode)
	if r.Signal != "" {
		what = fmt.Sprintf("%s ended by %s", routeName(r.Route), r.Signal)
	}
	detail := " · " + duration(r.Duration)
	// A change in the pool is shown only between two reported readings.
	if r.PoolBefore != nil && r.PoolAfter != nil && !r.Route.IsLocal() {
		detail += " · pool " + pctText(r.PoolBefore) + " → " + pctText(r.PoolAfter)
	}
	switch {
	case !r.InRepo:
		detail += " · files " + unknownText + " · commits " + unknownText
	default:
		if r.Files != nil {
			detail += " · " + plural(*r.Files, "file changed", "files changed")
		} else {
			detail += " · files " + unknownText
		}
		switch {
		case r.Commits == nil:
			detail += " · commits " + unknownText
		case *r.Commits > 0:
			detail += " · " + plural(*r.Commits, "commit", "commits")
		}
	}
	return line{sg(st, mark), sg(t.Plain, what), sg(t.Dim, detail)}
}

func (t Theme) ratingLine() line {
	return line{sg(t.Plain, "    How did it go?  "), sg(t.Key, "1"), sg(t.Dim, " solved  "), sg(t.Key, "2"), sg(t.Dim, " partly  "),
		sg(t.Key, "3"), sg(t.Dim, " wrong pick  "), sg(t.Key, "↵"), sg(t.Dim, " skip")}
}

// Ratings map keys to run-record outcomes.
var Ratings = map[string]string{"1": "solved", "2": "partly", "3": "wrong-pick"}

// pctInt rounds a percentage for the run record.
func PctInt(p *float64) *int {
	if p == nil {
		return nil
	}
	n := int(math.Round(*p))
	return &n
}
