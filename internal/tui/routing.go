package tui

import (
	"fmt"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// The routing screen: while the router reads pool usage and scores each
// CLI, the candidates are listed and tick off one by one.

const shimmerEvery = 55 * time.Millisecond // the light sweep over "Routing"

type progressMsg struct {
	p    engine.Progress
	ch   chan engine.Progress
	gen  int
	done bool
}

// listenProgress waits for the next routing step.
func listenProgress(ch chan engine.Progress, gen int) tea.Cmd {
	return func() tea.Msg {
		p, ok := <-ch
		return progressMsg{p: p, ch: ch, gen: gen, done: !ok}
	}
}

// routingProgress is what the router has said so far.
type routingProgress struct {
	started   bool
	task      string
	guessed   bool
	prefer    string
	harnesses []string
	routes    map[string]*engine.Route
	skipped   map[string]bool
}

func (r *routingProgress) add(p engine.Progress) {
	if r.routes == nil {
		r.routes, r.skipped = map[string]*engine.Route{}, map[string]bool{}
	}
	switch p.Kind {
	case "start":
		r.started = true
		r.task, r.guessed, r.prefer, r.harnesses = p.Task, p.Guessed, p.Prefer, p.Harnesses
	case "route":
		r.routes[p.Harness] = p.Route
	case "skip":
		r.skipped[p.Harness] = true
	}
}

// routingLines is the headline and one row per candidate CLI.
func (m *Model) routingLines() []line {
	t := m.theme
	el := m.opt.Now().Sub(m.started)
	glyph := "·"
	if m.opt.Motion {
		glyph = spinFrames[m.spin%len(spinFrames)]
	}
	head := line{sg(t.Accent, " "+glyph+" ")}
	head = append(head, m.shimmer("Routing", el)...)
	pr := m.prog
	if !pr.started {
		detail := m.card.Prefer
		if detail != "" {
			detail = "  " + detail
		}
		return []line{append(head, sg(t.Dim, detail+" · "+duration(el)))}
	}
	info := taskText(pr.task, pr.guessed) + " · " + pr.prefer + " · " + plural(len(pr.harnesses), "route", "routes")
	if m.opt.Motion {
		info += " · " + fmt.Sprintf("%.1fs", el.Seconds())
	}
	out := []line{append(head, sg(t.Dim, "  "+info))}
	for _, h := range pr.harnesses {
		r := engine.Route{Harness: h}
		switch {
		case pr.routes[h] != nil:
			x := *pr.routes[h]
			bench := x.BenchmarkName
			if bench == "" {
				bench = "score"
			}
			bench += " " + scoreText(x.BenchmarkScore)
			if x.BenchmarkBasis != "" {
				bench += " " + x.BenchmarkBasis
			}
			out = append(out, fitLine(line{sg(t.OK, "   ✓ "), t.logo(x), sg(t.Plain, " "+col(routeName(x), 13)+col(x.Model, 17)), sg(t.Dim, bench)}, boxW(m.width)))
		case pr.skipped[h]:
			out = append(out, line{sg(t.Dim, "   – "), t.logo(r), sg(t.Dim, " "+col(h, 13)+"no usable route for this task")})
		default:
			out = append(out, line{sg(t.Accent, "   "+glyph+" "), t.logo(r), sg(t.Plain, " "+col(h, 13)+col("", 17)), sg(t.Dim, "probing pool usage…")})
		}
	}
	return out
}

// shimmer is a word with a light sweeping across it (plain when motion
// is off).
func (m *Model) shimmer(word string, el time.Duration) line {
	t := m.theme
	if !m.opt.Motion {
		return line{sg(t.Bold, word)}
	}
	rs := []rune(word)
	pos := float64(int(el/shimmerEvery)%(len(rs)+10)) - 5
	var l line
	for i, r := range rs {
		d := float64(i) - pos
		if d < 0 {
			d = -d
		}
		st := t.Dim
		switch {
		case d < 1.2:
			st = t.Bold
		case d < 3:
			st = t.Plain
		}
		l = append(l, sg(st, string(r)))
	}
	return l
}
