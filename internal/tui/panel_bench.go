package tui

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/homelab-0/agent-flow-kit/internal/engine"

	tea "charm.land/bubbletea/v2"
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
	// ID is the source's id for afk bench source (empty for LMArena,
	// models.dev, ratings and estimates, which aren't blended sources).
	ID string
	// Own is a source the user added; Where is its URL or file.
	Own   bool
	Where string
	// Weight is its weight in a blend ("1", or per task "complex 2,
	// review 1"); empty for a source that isn't blended.
	Weight string
}

// benchDoneMsg is what an in-place source change said.
type benchDoneMsg struct {
	text string
	err  error
}

func (p *Panel) benchDo(op string, args ...string) tea.Cmd {
	src, ctx := p.src, p.ctx
	if src == nil {
		return nil
	}
	return func() tea.Msg {
		text, err := src.BenchDo(ctx, op, args...)
		return benchDoneMsg{text, err}
	}
}

// benchSourceKey is a key on the Sources view: space on/off, a add a
// source, w its weight, t read it now, x remove one of yours.
func (p *Panel) benchSourceKey(k, armed string) tea.Cmd {
	v := p.data.bench
	if k == "a" {
		p.ask = &panelAsk{tab: TabBench, label: "new source",
			hint: "An id, a URL or file (in quotes if it has spaces), and the tasks it scores (complex, standard, review, architecture, security, webdev, research, frontier). For example: my-evals https://example.com/board.json complex,review",
			done: func(text string) tea.Cmd { return p.benchDo("add", splitArgs(text)...) }}
		return nil
	}
	if v == nil || len(v.Sources) == 0 {
		return nil
	}
	s := v.Sources[min(p.sel[TabBench], len(v.Sources)-1)]
	switch k {
	case "space", " ":
		if !s.Read || s.Key == "" {
			p.notice = s.Name + " can't be turned off"
			return nil
		}
		return p.configSave(s.Key, map[bool]string{true: "off", false: "on"}[s.On])
	case "w":
		if s.Weight == "" {
			p.notice = s.Name + " isn't averaged with other sources, so it has no weight"
			return nil
		}
		id := s.ID
		p.ask = &panelAsk{tab: TabBench, label: "weight of " + s.Name, text: "",
			hint: "A number (1 is the usual, 2 counts twice, 0 leaves it out), then optionally the tasks it is for. For example: 2  or  0.5 review",
			done: func(text string) tea.Cmd {
				return p.benchDo("weight", append([]string{id}, strings.Fields(text)...)...)
			}}
		return nil
	case "t":
		if s.ID == "" || s.ID == "lmarena" {
			p.notice = s.Name + " is read by afk bench sync (s)"
			return nil
		}
		return p.run("bench", "source", "test", s.ID)
	case "x":
		switch {
		case !s.Own:
			p.notice = s.Name + " is built in; space turns it off"
		case armed == "bench:"+s.ID:
			return p.benchDo("rm", s.ID)
		default:
			p.cfgRemove = "bench:" + s.ID
			p.notice = "press x again to remove " + s.Name
		}
	}
	return nil
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
	nw, mw := 22, 32
	if w < 100 {
		mw = 24
	}
	out := []line{{sg(t.Dim, "   on  "+col("source", nw)+col("measures", mw)+col("weight", 9)+"used for")}}
	own := false
	for i, s := range v.Sources {
		dot := t.dot("")
		nst := t.Dim
		if s.On {
			dot, nst = t.dot("ok"), t.Plain
		}
		name := s.Name
		if s.Own {
			name += " ·yours"
			own = true
		}
		wt := s.Weight
		if wt == "" {
			wt = "–"
		} else if strings.Contains(wt, " ") {
			wt = "per task"
		}
		row := line{sg(t.Plain, "   "), dot, sg(t.Plain, "   "), sg(nst, col(name, nw-1)+" "), sg(t.Dim, col(s.Measures, mw-1)+" "), sg(t.Plain, col(wt, 9)), sg(t.Dim, s.UsedFor)}
		out = append(out, p.selRow(row, i, w))
	}
	if !own {
		out = append(out, line{sg(t.Dim, "   "), sg(t.Key, "a"), sg(t.Dim, " adds a leaderboard of your own: a JSON, YAML or CSV file or URL")})
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
		body = append(body, nil)
		if s.Where != "" {
			body = append(body, t.field("from", sg(t.Plain, truncate(s.Where, bx-16))))
		}
		if s.Key != "" {
			body = append(body, t.field("setting", sg(t.Plain, s.Key+" = "+state), sg(t.Dim, "   "), sg(t.Key, "space"), sg(t.Dim, " turns it "+map[bool]string{true: "off", false: "on"}[s.On])))
		}
		if s.Weight != "" {
			body = append(body, t.field("weight", sg(t.Plain, s.Weight), sg(t.Dim, "   "), sg(t.Key, "w"), sg(t.Dim, " changes it")))
		}
		if s.Status != "" {
			for i, l := range wrap(s.Status, bx-16) {
				lab := "last sync"
				if i > 0 {
					lab = ""
				}
				body = append(body, t.field(lab, sg(t.Plain, l)))
			}
		}
		if s.ID != "" && s.ID != "lmarena" {
			hint := line{sg(t.Key, "t"), sg(t.Dim, " reads it now and shows which models it matched")}
			if s.Own {
				hint = append(hint, sg(t.Dim, "   "), sg(t.Key, "x"), sg(t.Dim, " removes it"))
			}
			body = append(body, nil, hint)
		}
		out = append(out, nil, t.top(s.Name, bx, t.Border))
		for _, l := range body {
			out = append(out, t.boxLine(bx, t.Border, l))
		}
		out = append(out, t.bottom(bx, t.Border))
	}
	out = append(out, nil)
	for _, l := range wrap("When several sources score the same kind of task, AFK averages their scores by weight; Why AFK picks shows each part. A source that doesn't list a model adds nothing for it, since most boards are slow to add new models. An estimate is never averaged with a measurement. Changes apply at the next sync (s).", max(w-2, 20)) {
		out = append(out, line{sg(t.Dim, " "+l)})
	}
	return out, line{sg(t.Key, "space"), sg(t.Dim, " on/off  "), sg(t.Key, "a"), sg(t.Dim, " add  "), sg(t.Key, "w"), sg(t.Dim, " weight  "), sg(t.Key, "t"), sg(t.Dim, " test  "), sg(t.Key, "s"), sg(t.Dim, " sync now  ")}
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
	var body []line
	if len(r.BenchmarkParts) > 0 {
		body = append(body, t.field("benchmark", sg(t.Plain, fmt.Sprintf("%6s", scoreText(r.BenchmarkScore))), sg(t.Dim, "  weighted average of "+itoaN(len(r.BenchmarkParts))+" sources ("+r.BenchmarkBasis+")")))
		for _, bp := range r.BenchmarkParts {
			st := t.Plain
			note := "  × " + trimFloat(bp.Weight)
			if bp.Weight == 0 {
				st, note = t.Dim, "  × 0, left out"
			}
			if bp.Carried {
				note += " · last sync"
			}
			body = append(body, t.field("", sg(t.Dim, " "), sg(st, fmt.Sprintf("%5.1f", bp.Score)+"  "+bp.Label), sg(t.Dim, note)))
		}
	} else {
		body = append(body, t.field("benchmark", sg(t.Plain, fmt.Sprintf("%6s", scoreText(r.BenchmarkScore))), sg(t.Dim, "  "+r.BenchmarkName+" ("+r.BenchmarkBasis+")")))
	}
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

func trimFloat(f float64) string { return strconv.FormatFloat(f, 'f', -1, 64) }

// splitArgs splits a typed line into words, keeping a "quoted part" or
// 'quoted part' whole.
func splitArgs(s string) []string {
	var out []string
	var cur strings.Builder
	var q rune
	in := false
	for _, r := range s {
		switch {
		case q != 0:
			if r == q {
				q = 0
			} else {
				cur.WriteRune(r)
			}
		case r == '"' || r == '\'':
			q, in = r, true
		case r == ' ' || r == '\t':
			if in {
				out = append(out, cur.String())
				cur.Reset()
				in = false
			}
		default:
			cur.WriteRune(r)
			in = true
		}
	}
	if in {
		out = append(out, cur.String())
	}
	return out
}
