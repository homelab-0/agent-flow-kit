package tui

import (
	"fmt"
	"strings"
)

// The navigation strip: the seven places AFK has, shown the same way on
// the composer and on every tab, so they can always be seen and reached.
//
//	 1 Route  2 Harnesses  3 Benchmarks  4 Skills  5 MCP  6 Usage  7 Config       afk 0.4.0
//	─━━━━━━━━━────────────────────────────────────────────────────────────────────────────
//
// The open place is bright on the selection background with an accent
// rule under it; the others are dim, each with its number key.

// tabBlurbs say in a few words what each place is for (the line under the
// strip on a tab, and the command menu).
var tabBlurbs = []string{
	"describe a task and AFK routes it",
	"the agent CLIs on this machine: sign-in, models, usage, updates",
	"how each model scores, per kind of task",
	"skills, and which CLIs have them",
	"MCP servers, and which CLIs have them",
	"what is left on each plan, gateways and local models, and what ran",
	"every setting, changed in place",
}

// navLines is the strip and the rule under it, w cells wide.
func (t Theme) navLines(active Tab, w int, right string) []line {
	// Labels with their numbers when they fit; numbers only, with the open
	// place named, when they don't.
	full := 1
	for i, n := range tabNames {
		full += lenCells(fmt.Sprintf(" %d %s ", i+1, n))
	}
	short := full > w
	l := line{sg(t.Plain, " ")}
	rule := line{sg(t.Border, "─")}
	for i, n := range tabNames {
		num := fmt.Sprint(i + 1)
		var cell line
		if Tab(i) == active {
			cell = line{sg(t.Dim.Background(t.selbg), " "+num+" "), sg(t.Accent.Bold(true).Background(t.selbg), n+" ")}
		} else if short {
			cell = line{sg(t.Dim, " "+num+" ")}
		} else {
			cell = line{sg(t.Dim, " "+num+" "), sg(t.Plain, n+" ")}
		}
		l = append(l, cell...)
		if Tab(i) == active {
			rule = append(rule, sg(t.Accent, strings.Repeat("━", cell.width())))
		} else {
			rule = append(rule, sg(t.Border, strings.Repeat("─", cell.width())))
		}
	}
	if right != "" {
		if gap := w - l.width() - lenCells(right) - 1; gap > 1 {
			l = append(l, sg(t.Plain, strings.Repeat(" ", gap)), sg(t.Dim, right))
		}
	}
	if n := w - rule.width(); n > 0 {
		rule = append(rule, sg(t.Border, strings.Repeat("─", n)))
	}
	return []line{fitLine(l, w), fitLine(rule, w)}
}

// keyHint is one key and what it does, the key drawn as a small keycap.
func (t Theme) keyHint(key, what string) line {
	return line{sg(t.Key.Background(t.selbg), " "+key+" "), sg(t.Dim, what+"  ")}
}

// keyBars lays the tab's hints out from the left and the panel's own
// keys at the far right, on one row when they fit; else the tab's keys
// get a row of their own above the panel's. Hints that still don't fit
// give way from the end.
func (t Theme) keyBars(hints, right [][2]string, w int) []line {
	row := func(hs [][2]string) line {
		l := line{sg(t.Plain, " ")}
		for _, h := range hs {
			l = append(l, t.keyHint(h[0], h[1])...)
		}
		return l
	}
	l, r := row(hints), row(right)
	if gap := w - l.width() - r.width(); gap >= 0 {
		return []line{append(append(l, sg(t.Plain, strings.Repeat(" ", gap))), r[1:]...)}
	}
	for len(hints) > 1 && l.width() > w {
		hints = hints[:len(hints)-1]
		l = row(hints)
	}
	for len(right) > 1 && r.width() > w {
		right = right[:len(right)-1]
		r = row(right)
	}
	if len(hints) == 0 {
		return []line{fitLine(r, w)}
	}
	r = append(line{sg(t.Plain, strings.Repeat(" ", max(w-r.width(), 0)))}, r...)
	return []line{fitLine(l, w), fitLine(r, w)}
}

// hintPairs turns a tab's old-style hint line (key seg, text seg, ...)
// into pairs for the key bar.
func hintPairs(l line) [][2]string {
	var out [][2]string
	for i := 0; i+1 < len(l); i += 2 {
		k, v := strings.TrimSpace(l[i].s), strings.TrimSpace(l[i+1].s)
		if k == "" {
			continue
		}
		out = append(out, [2]string{k, v})
	}
	return out
}
