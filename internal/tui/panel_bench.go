package tui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// The Benchmarks tab's views, switched with [ and ].
const (
	benchBoard = iota
	benchSources
	benchWhy
)

var benchViews = []string{"Leaderboard", "Sources", "Why AFK picks"}

// BenchSource is one place scores come from.
type BenchSource struct {
	// Key is the setting that turns it on or off ("" when it can't be),
	// e.g. bench.sources.lmarena.enabled or route.learn.
	Key      string
	Name     string
	Measures string
	UsedFor  string
	On       bool
	// Read says AFK reads this source today; a source it doesn't read
	// yet is listed so you can see what isn't in the scores.
	Read bool
	// Status is the last sync's word on it ("live", "offline", ...),
	// and About a longer description.
	Status, About string
}

func (p *Panel) benchTaskLine() line {
	t := p.theme
	cur := benchTasks[p.taskIdx%len(benchTasks)]
	l := line{sg(t.Dim, " task  ")}
	for _, k := range benchTasks {
		if k == cur {
			l = append(l, line{sg(t.Accent.Bold(true), "‹"+k+"›")}.on(t.SelBG)...)
			l = append(l, sg(t.Plain, " "))
		} else {
			l = append(l, sg(t.Dim, " "+k+"  "))
		}
	}
	return l
}

func (p *Panel) benchLines(w int) ([]line, line) {
	t := p.theme
	view := p.viewOf(TabBench)
	out := []line{t.subtabs(benchViews, view), nil}
	var body []line
	var hint line
	switch view {
	case benchSources:
		body, hint = p.benchSourceLines(w)
	case benchWhy:
		body, hint = p.benchWhyLines(w)
	default:
		body, hint = p.benchBoardLines(w)
	}
	return append(out, body...), hint
}

// viaLogos is a model's routes as logos in a fixed 9 cells: up to three,
// else two and a count.
func (t Theme) viaLogos(via []engine.Route) line {
	l := line{}
	for j, x := range via {
		if len(via) > 3 && j == 2 {
			l = append(l, sg(t.Dim, fmt.Sprintf("+%d", len(via)-2)))
			break
		}
		l = append(l, t.logo(x), sg(t.Plain, " "))
	}
	return fitLine(l, 9).pad(9, t.Plain)
}

func ratingsText(r BenchRow) string {
	if r.Solved+r.Partly+r.Wrong == 0 {
		return "—"
	}
	var parts []string
	if r.Solved > 0 {
		parts = append(parts, fmt.Sprintf("%d✓", r.Solved))
	}
	if r.Partly > 0 {
		parts = append(parts, fmt.Sprintf("%d~", r.Partly))
	}
	if r.Wrong > 0 {
		parts = append(parts, fmt.Sprintf("%d✗", r.Wrong))
	}
	return strings.Join(parts, " ")
}

func (p *Panel) benchBoardLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.bench
	cur := benchTasks[p.taskIdx%len(benchTasks)]
	out := []line{p.benchTaskLine()}
	if v.Source != "" {
		out = append(out, line{sg(t.Dim, " scored by  "), sg(t.Plain, v.Source)})
	}
	bw := 12
	if w >= 100 {
		bw = 20
	}
	// The bars start a little under the lowest score shown, so close
	// scores look different; the header says where.
	lo := 100.0
	for _, r := range v.Rows {
		if r.Score != nil {
			lo = min(lo, *r.Score)
		}
	}
	lo = max(0, float64(int((lo-5)/10))*10)
	if lo >= 100 {
		lo = 0
	}
	scoreHead := "score"
	if lo > 0 {
		scoreHead = fmt.Sprintf("score (bars from %.0f)", lo)
	}
	out = append(out, nil, line{sg(t.Dim, "   #  "+col("model", 20)+col("via", 10)+col(scoreHead, bw+8)+col("basis", 10)+"your runs")})
	for i, r := range v.Rows {
		row := append(line{sg(t.Dim, fmt.Sprintf(" %2d  ", i+1)), sg(t.Plain, col(r.Model, 20))}, t.viaLogos(r.Via)...)
		row = append(row, sg(t.Plain, " "))
		if r.Score != nil {
			pct := *r.Score
			row = append(row, p.wideMeterAccent((pct-lo)*100/(100-lo), bw)...)
			row = append(row, sg(t.Plain, fmt.Sprintf("  %5.1f ", pct)))
		} else {
			row = append(row, sg(t.Dim, strings.Repeat("·", bw)+"    n/a "))
		}
		bst := t.OK
		switch r.Basis {
		case "estimate", "stale":
			bst = t.Dim
		case "capped", "partial":
			bst = t.Warn
		}
		row = append(row, sg(bst, " "+col(r.Basis, 10)), sg(t.Plain, ratingsText(r)))
		out = append(out, p.selRow(row, i, w))
	}
	if len(v.Rows) == 0 {
		out = append(out, line{sg(t.Dim, "   no model on your CLIs is scored for "+cur)})
	}
	if best, ok := bestRoute(v.Routes); ok {
		bx := boxW(w)
		body := []line{{t.logo(best), sg(t.Bold, " "+best.Model), sg(t.Dim, routeEffort(best)+"   "), sg(t.Plain, "effective "+scoreText(best.EffectiveScore)), sg(t.Dim, " = benchmark "+scoreText(best.BenchmarkScore)+partsText(best.ScoreParts))}}
		if second, ok := runnerUp(v.Routes, best); ok {
			gap := ""
			if best.EffectiveScore != nil && second.EffectiveScore != nil {
				gap = fmt.Sprintf(" · %.1f behind", *best.EffectiveScore-*second.EffectiveScore)
			}
			body = append(body, line{sg(t.Dim, "runner-up "), t.logo(second), sg(t.Plain, " "+second.Model+" "+scoreText(second.EffectiveScore)), sg(t.Dim, gap+"   "), sg(t.Key, "]"), sg(t.Dim, " why")})
		}
		out = append(out, nil, t.top("AFK would pick for "+cur+" right now", bx, t.Border))
		for _, l := range body {
			out = append(out, t.boxLine(bx, t.Border, l))
		}
		out = append(out, t.bottom(bx, t.Border))
	}
	if v.Problems != "" {
		out = append(out, nil, line{sg(t.Warn, " "+v.Problems)})
	}
	out = append(out, nil,
		line{sg(t.OK, " measured"), sg(t.Dim, " read off a leaderboard   "), sg(t.Warn, "capped"), sg(t.Dim, " the board doesn't list it")},
		line{sg(t.Dim, " estimate AFK's catalog figure, not measured")},
		line{sg(t.Dim, " your runs: your ratings after runs, ✓ solved  ~ partly  ✗ wrong pick")})
	return out, line{sg(t.Key, "←→"), sg(t.Dim, " task  "), sg(t.Key, "s"), sg(t.Dim, " sync  ")}
}

// wideMeterAccent is a 0-100 score as a bar n cells wide with eighth
// blocks, so close scores still differ.
func (p *Panel) wideMeterAccent(score float64, n int) line {
	t := p.theme
	eighths := int(max(0, min(100, score)) * float64(n*8) / 100)
	full, part := eighths/8, eighths%8
	s := strings.Repeat("█", full)
	if part > 0 && full < n {
		s += string([]rune("▏▎▍▌▋▊▉")[part-1])
	}
	rest := n - lenCells(s)
	return line{sg(t.Accent, s), sg(t.Dim, strings.Repeat("░", max(rest, 0)))}
}

// routeEffort is " · high" for a route with an effort, else "".
func routeEffort(r engine.Route) string {
	if r.Effort == "" {
		return ""
	}
	return " · " + r.Effort
}

// partsText is the adjustments as " + 3.3 headroom - 0.5 …".
func partsText(parts []engine.ScorePart) string {
	var b strings.Builder
	for _, pt := range parts {
		if pt.Points == 0 {
			continue
		}
		sign := "+"
		if pt.Points < 0 {
			sign = "−"
		}
		fmt.Fprintf(&b, " %s %.1f", sign, abs(pt.Points))
	}
	return b.String()
}

func abs(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}

// ranked is the routes best first by effective score; ones without a
// score go last.
func ranked(routes []engine.Route) []engine.Route {
	out := append([]engine.Route(nil), routes...)
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i].EffectiveScore, out[j].EffectiveScore
		switch {
		case a == nil:
			return false
		case b == nil:
			return true
		}
		return *a > *b
	})
	return out
}

func bestRoute(routes []engine.Route) (engine.Route, bool) {
	r := ranked(routes)
	if len(r) == 0 || r[0].EffectiveScore == nil {
		return engine.Route{}, false
	}
	return r[0], true
}

func runnerUp(routes []engine.Route, best engine.Route) (engine.Route, bool) {
	r := ranked(routes)
	if len(r) < 2 || r[1].EffectiveScore == nil {
		return engine.Route{}, false
	}
	return r[1], true
}

func (p *Panel) benchSourceLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.bench
	out := []line{{sg(t.Dim, "   on  "+col("source", 24)+col("measures", 34)+"used for")}}
	for i, s := range v.Sources {
		dot := t.dot("")
		nst := t.Dim
		switch {
		case !s.Read:
		case s.On:
			dot, nst = t.dot("ok"), t.Plain
		}
		row := line{sg(t.Plain, "   "), dot, sg(t.Plain, "   "), sg(nst, col(s.Name, 24)), sg(t.Dim, col(s.Measures, 34)), sg(t.Dim, s.UsedFor)}
		out = append(out, p.selRow(row, i, w))
	}
	if len(v.Sources) > 0 {
		s := v.Sources[min(p.sel[TabBench], len(v.Sources)-1)]
		bx := boxW(w)
		var body []line
		for _, l := range wrap(s.About, bx-6) {
			body = append(body, line{sg(t.Plain, l)})
		}
		state := "on"
		if !s.On {
			state = "off"
		}
		switch {
		case !s.Read:
			body = append(body, nil, line{sg(t.Warn, "AFK doesn't read this source yet, so none of the scores come from it.")})
		case s.Key != "":
			body = append(body, nil, line{sg(t.Dim, "setting  "), sg(t.Plain, s.Key+" = "+state), sg(t.Dim, "   "), sg(t.Key, "space"), sg(t.Dim, " turns it "+map[bool]string{true: "off", false: "on"}[s.On])})
		}
		if s.Status != "" {
			body = append(body, line{sg(t.Dim, "last sync "), sg(t.Plain, s.Status)})
		}
		out = append(out, nil, t.top(s.Name, bx, t.Border))
		for _, l := range body {
			out = append(out, t.boxLine(bx, t.Border, l))
		}
		out = append(out, t.bottom(bx, t.Border))
	}
	out = append(out, nil)
	for _, l := range wrap("Each kind of task is scored by one source today: the leaderboard that measures that kind of work, else AFK's built-in estimate, marked as one. Your ratings then move a model up or down once it has a few rated runs.", max(w-2, 20)) {
		out = append(out, line{sg(t.Dim, " "+l)})
	}
	return out, line{sg(t.Key, "space"), sg(t.Dim, " on/off  "), sg(t.Key, "s"), sg(t.Dim, " sync now  ")}
}

func (p *Panel) benchWhyLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.bench
	cur := benchTasks[p.taskIdx%len(benchTasks)]
	out := []line{p.benchTaskLine(), nil}
	rs := ranked(v.Routes)
	if len(rs) == 0 {
		msg := "   no route for " + cur + " on your CLIs right now"
		if v.Problems != "" {
			msg = "   " + v.Problems
		}
		return append(out, line{sg(t.Dim, msg)}), line{sg(t.Key, "←→"), sg(t.Dim, " task  ")}
	}
	out = append(out, line{sg(t.Dim, "   #  "+col("route", 34)+col("benchmark", 11)+col("adjusted", 10)+"effective")})
	for i, r := range rs {
		adj := 0.0
		for _, pt := range r.ScoreParts {
			adj += pt.Points
		}
		adjText := fmt.Sprintf("%+.1f", adj)
		row := line{sg(t.Dim, fmt.Sprintf(" %2d  ", i+1)), t.logo(r), sg(t.Plain, " "+col(r.Model+routeEffort(r), 31)), sg(t.Plain, col(scoreText(r.BenchmarkScore), 11)), sg(t.Dim, col(adjText, 10)), sg(t.Bold, scoreText(r.EffectiveScore))}
		if i == 0 {
			row = append(row, sg(t.OK, "  ← AFK's pick"))
		}
		out = append(out, p.selRow(row, i, w))
	}
	r := rs[min(p.sel[TabBench], len(rs)-1)]
	bx := boxW(w)
	body := []line{t.field("benchmark", sg(t.Plain, fmt.Sprintf("%6s", scoreText(r.BenchmarkScore))), sg(t.Dim, "  "+r.BenchmarkName+" ("+r.BenchmarkBasis+")"))}
	for _, pt := range r.ScoreParts {
		st := t.OK
		if pt.Points < 0 {
			st = t.Warn
		}
		body = append(body, t.field("", sg(st, fmt.Sprintf("%+6.1f", pt.Points)), sg(t.Dim, "  "+pt.Label)))
	}
	body = append(body, line{sg(t.Border, strings.Repeat("─", min(bx-6, 60)))},
		t.field("effective", sg(t.Bold, fmt.Sprintf("%6s", scoreText(r.EffectiveScore))), sg(t.Dim, fmt.Sprintf("  #%d of %d", min(p.sel[TabBench], len(rs)-1)+1, len(rs)))))
	out = append(out, nil, t.top("Why "+r.Model+" scores "+scoreText(r.EffectiveScore)+" for "+cur, bx, t.Border))
	for _, l := range body {
		out = append(out, t.boxLine(bx, t.Border, l))
	}
	out = append(out, t.bottom(bx, t.Border))
	out = append(out, nil)
	for _, l := range wrap("These are the best route on each CLI for this kind of task, ranked as AFK would rank them now with your plans' headroom. A task you type can also move scores by its risk and size.", max(w-2, 20)) {
		out = append(out, line{sg(t.Dim, " "+l)})
	}
	return out, line{sg(t.Key, "←→"), sg(t.Dim, " task  ")}
}
