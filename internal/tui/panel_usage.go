package tui

import (
	"fmt"
	"strings"
	"time"

	"charm.land/lipgloss/v2"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// The Usage tab (TabRuns) has three views, switched with [ and ].
const (
	usagePlans = iota
	usageEngines
	usageRuns
)

var usageViews = []string{"Plans", "Engines", "Run history"}

// tabViews are the views a tab steps through with [ and ], or nil.
func tabViews(t Tab) []string {
	switch t {
	case TabRuns:
		return usageViews
	case TabBench:
		return benchViews
	}
	return nil
}

// viewOf is the open view of a tab.
func (p *Panel) viewOf(t Tab) int {
	if n := len(tabViews(t)); n > 0 {
		return ((p.view[t] % n) + n) % n
	}
	return 0
}

// stepView moves a tab with views to the next (+1) or previous (-1) one.
func (p *Panel) stepView(step int) bool {
	n := len(tabViews(p.tab))
	if n == 0 {
		return false
	}
	p.view[p.tab] = ((p.view[p.tab]+step)%n + n) % n
	p.sel[p.tab] = 0
	return true
}

// subtabs is a tab's views, the open one highlighted, with the keys that
// switch them.
func (t Theme) subtabs(names []string, active int) line {
	l := line{sg(t.Plain, " ")}
	for i, n := range names {
		if i == active {
			l = append(l, line{sg(t.Accent.Bold(true), " "+n+" ")}.on(t.SelBG)...)
		} else {
			l = append(l, sg(t.Dim, " "+n+" "))
		}
		l = append(l, sg(t.Plain, " "))
	}
	return append(l, sg(t.Dim, "  "), sg(t.Key, "["), sg(t.Dim, " "), sg(t.Key, "]"), sg(t.Dim, " switch view"))
}

func (p *Panel) usageLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.status
	view := p.viewOf(TabRuns)
	head := t.subtabs(usageViews, view)
	if !v.Updated.IsZero() {
		head = append(head, sg(t.Dim, "   updated "+v.Updated.Format("15:04")))
	}
	out := []line{head, nil}
	var body []line
	var hint line
	switch view {
	case usagePlans:
		body, hint = p.planCards(w)
	case usageEngines:
		body, hint = p.engineLines(w)
	default:
		body, hint = p.runLines(w)
	}
	return append(out, body...), hint
}

// planCards are the plans side by side, as many to a row as fit.
func (p *Panel) planCards(w int) ([]line, line) {
	t := p.theme
	v := p.data.status
	var hint line
	if p.anySetAside() {
		hint = line{sg(t.Key, "c"), sg(t.Dim, " clear set-aside  ")}
	}
	if len(v.Plans) == 0 {
		return []line{{sg(t.Dim, " No plan found: sign in to claude, codex, grok or agy and press "), sg(t.Key, "r"), sg(t.Dim, ".")}}, hint
	}
	per := max(1, min(3, (w-1)/35))
	cw := min((w-1)/per-1, 44)
	sel := min(p.sel[TabRuns], len(v.Plans)-1)
	var out []line
	for at := 0; at < len(v.Plans); at += per {
		var cards [][]line
		tall := 0
		for i := at; i < min(at+per, len(v.Plans)); i++ {
			c := p.planCard(v.Plans[i], cw-4)
			cards = append(cards, c)
			tall = max(tall, len(c))
		}
		rows := make([]line, tall+2)
		for i, c := range cards {
			pl := v.Plans[at+i]
			border := t.Border
			if at+i == sel {
				border = t.Accent
			}
			title := line{sg(border, "╭─ "), harnessLogo(t, pl.Harness), sg(t.Bold, " "+pl.Plan+" ")}
			title = append(title, sg(border, strings.Repeat("─", max(cw-title.width()-1, 0))+"╮"))
			rows[0] = append(rows[0], append(line{sg(t.Plain, " ")}, fitLine(title, cw)...)...)
			for j := range tall {
				var body line
				if j < len(c) {
					body = c[j]
				}
				rows[j+1] = append(rows[j+1], sg(t.Plain, " "), sg(border, "│ "))
				rows[j+1] = append(rows[j+1], fitLine(body, cw-4).pad(cw-4, t.Plain)...)
				rows[j+1] = append(rows[j+1], sg(border, " │"))
			}
			rows[tall+1] = append(rows[tall+1], sg(t.Plain, " "), sg(border, "╰"+strings.Repeat("─", cw-2)+"╯"))
		}
		out = append(out, rows...)
	}
	out = append(out, nil)
	var aside []PlanRow
	for _, pl := range v.Plans {
		if pl.SetAside {
			aside = append(aside, pl)
		}
	}
	if len(aside) == 0 {
		out = append(out, line{sg(t.Accent.Bold(true), " SET ASIDE"), sg(t.Dim, "  none: no plan is being avoided after a failed run")})
	} else {
		out = append(out, t.groupHead("Set aside", len(aside)))
		for _, pl := range aside {
			out = append(out, line{sg(t.Plain, " "), harnessLogo(t, pl.Harness), sg(t.Plain, " "+pl.Plan+"  "), sg(t.Warn, pl.Note)})
		}
	}
	out = append(out, nil)
	for _, l := range wrap("Figures are what each CLI reported. \"no limit on this plan\" is the plan's own rule as its CLI listed it; AFK never fills in a figure it wasn't given.", max(w-2, 20)) {
		out = append(out, line{sg(t.Dim, " "+l)})
	}
	return out, append(line{sg(t.Key, "←→"), sg(t.Dim, " plan  ")}, hint...)
}

// planCard is one plan's lines inside its card, w cells wide.
func (p *Panel) planCard(pl PlanRow, w int) []line {
	t := p.theme
	var out []line
	window := func(label string, pct *float64, none bool, resets time.Time) {
		switch {
		case pct != nil:
			out = append(out, append(append(line{sg(t.Dim, col(label, 7))}, p.wideMeter(pct, min(14, w-12))...), sg(t.Plain, " "+pctText(pct))))
		case none:
			out = append(out, line{sg(t.Dim, col(label, 7)), sg(t.Accent, "no limit on this plan")})
		default:
			out = append(out, line{sg(t.Dim, col(label, 7)), sg(t.Dim, "unknown")})
		}
		if !resets.IsZero() && pct != nil {
			out = append(out, line{sg(t.Dim, strings.Repeat(" ", 7)+"resets "+resetText(resets, p.now()))})
		}
	}
	known := pl.Week != nil || pl.FiveHour != nil || pl.NoWeek || pl.NoFiveHour
	if known {
		week, five := time.Time{}, time.Time{}
		if pl.ResetsWindow == "weekly" {
			week = pl.Resets
		} else if pl.ResetsWindow == "5h" {
			five = pl.Resets
		}
		window("week", pl.Week, pl.NoWeek, week)
		window("5-hour", pl.FiveHour, pl.NoFiveHour, five)
	}
	if pl.Pace != "" {
		out = append(out, nil)
		st := t.Plain
		if pl.Leans {
			st = t.OK
		}
		for i, l := range wrap(pl.Pace, max(w-7, 10)) {
			lab := "pace"
			if i > 0 {
				lab = ""
			}
			out = append(out, line{sg(t.Dim, col(lab, 7)), sg(st, l)})
		}
	}
	if pl.Note != "" && !pl.SetAside {
		if len(out) > 0 {
			out = append(out, nil)
		}
		for _, l := range wrap(pl.Note, w) {
			out = append(out, line{sg(t.Dim, l)})
		}
	}
	if len(out) == 0 {
		out = append(out, line{sg(t.Dim, "usage not reported")})
	}
	state, text := signInState(HarnessRow{SignIn: pl.SignIn})
	if pl.SetAside {
		state, text = "bad", "set aside after a failed run"
	}
	out = append(out, nil, line{t.dot(state), sg(t.Dim, " "+text+" · "+plural(pl.RunsToday, "run", "runs")+" today")})
	return out
}

// wideMeter is a headroom bar n cells wide.
func (p *Panel) wideMeter(pct *float64, n int) line {
	t := p.theme
	n = max(n, 4)
	f := meterCells(*pct, n, 1)
	return line{sg(t.style(t.headroom(pct)), strings.Repeat("█", f)), sg(t.Dim, strings.Repeat("░", n-f))}
}

// resetText is when a window resets: the time today, else the weekday.
func resetText(at, now time.Time) string {
	at = at.In(now.Location())
	y1, m1, d1 := at.Date()
	y2, m2, d2 := now.Date()
	if y1 == y2 && m1 == m2 && d1 == d2 {
		return at.Format("15:04")
	}
	if at.Sub(now) < 6*24*time.Hour {
		return at.Format("Mon 15:04")
	}
	return at.Format("Jan 2 15:04")
}

// engineLines are the model gateway and the local engines.
func (p *Panel) engineLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.status
	var out []line
	if v.Gateway == nil && len(v.Engines) == 0 {
		return []line{{sg(t.Dim, " No gateway set and no local engine found. Add a gateway on the Config tab; AFK finds Ollama, LM Studio, llama.cpp, vLLM and other engines on their usual ports by itself.")}}, nil
	}
	if g := v.Gateway; g != nil {
		out = append(out, t.groupHead("Gateway", 1))
		r := engine.Route{LaunchClass: "claude-gateway", GatewayKind: g.Kind}
		st := "ok"
		if g.State != "up" {
			st = "bad"
		}
		out = append(out, line{sg(t.Plain, " "), t.logo(r), sg(t.Plain, " "+col(g.Name, 20)+" "), t.dot(st), sg(t.Plain, " "+col(g.State, 8)), sg(t.Dim, g.Detail)})
		if g.Engine != "" {
			out = append(out, line{sg(t.Dim, "   └ "), t.engineLogo(g.Engine), sg(t.Plain, " "+col(engineName(g.Engine), 14)), sg(t.Dim, g.EngineHost)})
		}
		out = append(out, nil)
	}
	if len(v.Engines) > 0 {
		out = append(out, t.groupHead("Local engines", len(v.Engines)))
	}
	for i, e := range v.Engines {
		st, state := "ok", e.State
		if state == "" {
			st, state = "", unknownText
		}
		detail := e.Where
		if len(e.Models) > 0 {
			detail += " · " + plural(len(e.Models), "model", "models")
		}
		if e.NoAPI {
			st, state = "partly", "no API"
			detail += " · needs a gateway"
		}
		out = append(out, p.selRow(line{sg(t.Plain, " "), t.engineLogo(e.Engine), sg(t.Plain, " "+col(engineName(e.Engine), 20)+" "), t.dot(st), sg(t.Plain, " "+col(state, 8)), sg(t.Dim, detail)}, i, w))
	}
	if len(v.Engines) > 0 {
		e := v.Engines[min(p.sel[TabRuns], len(v.Engines)-1)]
		if e.NoAPI {
			out = append(out, nil)
			out = append(out, t.wrapField("note", engineName(e.Engine)+" has no Anthropic Messages API, so Claude Code can't run on it and AFK sends it nothing. Put a gateway in front of it (LiteLLM, agentgateway, ...) and add that gateway on the Config tab.", w-2)...)
		}
		if len(e.Models) > 0 {
			out = append(out, nil)
			out = append(out, t.wrapField("models", strings.Join(e.Models, ", "), w-2)...)
		}
	}
	return out, nil
}

// runLines are the recorded runs with the selected one in full.
func (p *Panel) runLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.status
	if len(v.Runs) == 0 {
		return []line{{sg(t.Dim, " No runs yet. A run is recorded when a session AFK started ends.")}}, nil
	}
	now := p.now()
	out := []line{{sg(t.Dim, "   "+col("started", 11)+col("route", 30)+col("where", 8)+col("took", 8)+col("result", 11)+"rating")}}
	for i, r := range v.Runs {
		res, rst := runResult(t, r)
		rate, rtst := runRating(t, r)
		route := r.Model
		if r.Effort != "" {
			route += " · " + r.Effort
		}
		row := line{sg(t.Dim, "  "+col(startedText(r.Started, now), 11)), harnessLogo(t, r.CLI), sg(t.Plain, " "+col(route, 27)), sg(t.Dim, col(r.Where, 8)), sg(t.Plain, col(ago(r.Duration), 8)), sg(rst, col(res, 11)), sg(rtst, rate)}
		out = append(out, p.selRow(row, i, w))
	}
	r := v.Runs[min(p.sel[TabRuns], len(v.Runs)-1)]
	bw := boxW(w)
	body := []line{t.field("run", sg(t.Plain, r.ID))}
	route := line{harnessLogo(t, r.CLI), sg(t.Plain, " "+r.CLI+" · "+r.Model)}
	if r.Effort != "" {
		route = append(route, sg(t.Plain, " · "+r.Effort))
	}
	body = append(body, t.field("route", route...))
	if r.Where != "" {
		body = append(body, t.field("where", sg(t.Plain, r.Where)))
	}
	if !r.Started.IsZero() {
		body = append(body, t.field("started", sg(t.Plain, r.Started.In(now.Location()).Format("Mon Jan 2 15:04")), sg(t.Dim, " · took "+ago(r.Duration))))
	}
	if r.PoolBefore != nil && r.PoolAfter != nil {
		body = append(body, t.field("plan", sg(t.Plain, fmt.Sprintf("%d%% → %d%% left", *r.PoolBefore, *r.PoolAfter))))
	}
	if r.Files != nil || r.Commits != nil {
		var parts []string
		if r.Files != nil {
			parts = append(parts, plural(*r.Files, "file", "files"))
		}
		if r.Commits != nil {
			parts = append(parts, plural(*r.Commits, "commit", "commits"))
		}
		body = append(body, t.field("changed", sg(t.Plain, strings.Join(parts, ", "))))
	}
	rate, rtst := runRating(t, r)
	body = append(body, t.field("rating", sg(rtst, rate), sg(t.Dim, "  (/rate in the composer rates the last run)")))
	out = append(out, nil, t.top(r.ID, bw, t.Border))
	for _, l := range body {
		out = append(out, t.boxLine(bw, t.Border, l))
	}
	out = append(out, t.bottom(bw, t.Border))
	return out, nil
}

func runResult(t Theme, r RunRow) (string, lipgloss.Style) {
	if r.Exit != 0 {
		return fmt.Sprintf("! exit %d", r.Exit), t.Bad
	}
	return "✓ done", t.OK
}

func runRating(t Theme, r RunRow) (string, lipgloss.Style) {
	switch r.Outcome {
	case "solved":
		return "solved", t.OK
	case "partly":
		return "partly", t.Warn
	case "wrong-pick":
		return "wrong pick", t.Bad
	}
	return "—", t.Dim
}

// startedText is when a run started: the time today, "yesterday", else
// the date.
func startedText(at, now time.Time) string {
	if at.IsZero() {
		return "—"
	}
	at = at.In(now.Location())
	day := func(x time.Time) time.Time { y, m, d := x.Date(); return time.Date(y, m, d, 0, 0, 0, 0, x.Location()) }
	switch day(now).Sub(day(at)) / (24 * time.Hour) {
	case 0:
		return at.Format("15:04")
	case 1:
		return "yesterday"
	}
	return at.Format("Jan 2")
}
