package tui

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

// Layout widths: the card is designed for 80 columns and draws a 76-cell
// box; below 70 columns it switches to the compact card.
const (
	boxWidth     = 76
	compactBelow = 70
	plainBelow   = 40
)

// Card is everything the route card shows.
type Card struct {
	Prompt  string
	Task    string
	Guessed bool
	Prefer  string
	Rows    []engine.Route
	Sel     int
	Efforts map[int]string // effort chosen with tab, per row
	Yolo    bool
	// Mode is the permission mode the router was asked with; ModeNotes
	// say, per CLI, when it runs a stricter one.
	Mode      string
	ModeNotes map[string]string
	Prog      float64 // meter fill, 0..1
	Pools     *engine.Pools
	Now       time.Time
	Loc       *time.Location
}

// Route is row i with the user's effort applied.
func (c Card) Route(i int) engine.Route {
	r := c.Rows[i]
	if e, ok := c.Efforts[i]; ok && e != r.Effort {
		return r.WithEffort(e)
	}
	return r
}

func (c Card) loc() *time.Location {
	if c.Loc == nil {
		return time.Local
	}
	return c.Loc
}

func (c Card) now() time.Time {
	if c.Now.IsZero() {
		return time.Now()
	}
	return c.Now
}

func boxW(width int) int {
	if width <= 0 || width > boxWidth {
		return boxWidth
	}
	return width
}

// --- box pieces -------------------------------------------------------

func (t Theme) top(title string, w int, border lipgloss.Style) line {
	if title == "" {
		return line{sg(border, "╭"+strings.Repeat("─", w-2)+"╮")}
	}
	title = truncate(title, w-6)
	rest := w - 5 - lenCells(title)
	return line{sg(border, "╭─ "), sg(t.Bold, title), sg(border, " "+strings.Repeat("─", max(rest, 0))+"╮")}
}

func (t Theme) bottom(w int, border lipgloss.Style) line {
	return line{sg(border, "╰"+strings.Repeat("─", w-2)+"╯")}
}

// boxLine is one line inside a box: "│ " + content padded + " │".
func (t Theme) boxLine(w int, border lipgloss.Style, content line) line {
	inner := append(line{sg(t.Plain, " ")}, content...)
	inner = fitLine(inner, w-3)
	out := line{sg(border, "│")}
	out = append(out, inner.pad(w-3, t.Plain)...)
	return append(out, sg(t.Plain, " "), sg(border, "│"))
}

// fitLine cuts a line to w cells, ending the last kept seg in ….
func fitLine(l line, w int) line {
	if l.width() <= w {
		return l
	}
	var out line
	used := 0
	for _, s := range l {
		n := lenCells(s.s)
		if used+n <= w {
			out = append(out, s)
			used += n
			continue
		}
		out = append(out, seg{s.st, truncate(s.s+"…", w-used)})
		break
	}
	return out
}

func lenCells(s string) int { return line{seg{s: s}}.width() }

// --- the route card ---------------------------------------------------

func (t Theme) promptLine(prompt string, width int) line {
	w := width
	if w <= 0 {
		w = boxWidth
	}
	if prompt == "" {
		return line{sg(t.Accent, "› "), sg(t.Dim, truncate("no prompt: the CLI opens without one", w-2))}
	}
	return line{sg(t.Accent, "› "), sg(t.Plain, truncate(oneLine(prompt), w-2))}
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

func (t Theme) yoloTag() seg { return sg(t.YoloTag, " yolo ") }

// routeBox is the box for the selected row.
func (t Theme) routeBox(c Card, w int) []line {
	r := c.Route(c.Sel)
	head := line{sg(t.Badge(badge(r)), badge(r)), sg(t.Bold, " "+routeName(r)), sg(t.Dim, " · "), sg(t.Plain, r.Model),
		sg(t.Dim, " · effort "), sg(t.Plain, effortText(r.Effort))}
	if r.EffortEscalated && r.Effort == c.Rows[c.Sel].Effort {
		head = append(head, sg(t.Dim, "      "), sg(t.Warn, "↑ escalated"))
	}
	if c.Yolo {
		head = append(head, sg(t.Plain, "  "), t.yoloTag())
	} else if c.Mode != "" && c.Mode != "ask" {
		head = append(head, sg(t.Dim, "  mode "), sg(t.Plain, c.Mode))
	}
	out := []line{t.top("Route", w, t.Border), t.boxLine(w, t.Border, head)}
	out = append(out, t.boxLine(w, t.Border, line{sg(t.Dim, "  "+taskText(c.Task, c.Guessed)+" · "+loginText(r))}))
	if n := c.ModeNotes[r.Harness]; n != "" && !c.Yolo {
		out = append(out, t.boxLine(w, t.Border, line{sg(t.Warn, "  "+n)}))
	}
	out = append(out, t.boxLine(w, t.Border, nil))
	why := wrap(reasonText(c.Rows, c.Sel, c.Task, c.now().In(c.loc())), w-8)
	for len(why) < 2 {
		why = append(why, "")
	}
	if len(why) > 2 {
		why = []string{why[0], truncate(why[1]+" "+why[2], w-8)}
	}
	for _, l := range why {
		out = append(out, t.boxLine(w, t.Border, line{sg(t.Plain, "  "+l)}))
	}
	out = append(out, t.boxLine(w, t.Border, nil))
	out = append(out, t.boxLine(w, t.Border, t.poolLine(c, r)))
	return append(out, t.bottom(w, t.Border))
}

func (t Theme) poolLine(c Card, r engine.Route) line {
	if r.IsGateway() {
		where := "the model gateway"
		if h := gatewayHost(r); h != "" {
			where = "the gateway at " + h
		}
		return line{sg(t.Dim, "  runs on  "), sg(t.Badge("GW"), "GW"), sg(t.Plain, " "+where), sg(t.Dim, " · state "+unknownText)}
	}
	l := line{sg(t.Dim, "  pool  ")}
	l = append(l, t.meter(r.PoolHeadroomPct, c.Prog)...)
	if r.PoolHeadroomPct != nil {
		l = append(l, sg(t.Plain, " "+pctText(r.PoolHeadroomPct)+" left"))
		if r.PoolQuotaSource == "local_5h_activity" {
			l = append(l, sg(t.Dim, " (estimated)"))
		}
	} else {
		l = append(l, sg(t.Dim, " "+unknownText))
	}
	return append(l, sg(t.Dim, " · 5h window "+resetsText(c.Pools, r.EntitlementPool, c.loc())))
}

func modelCol(w int) int { return max(17-(boxWidth-w), 8) }

func (t Theme) tableHeader(w int) line {
	return line{sg(t.Dim, "      "+col("route", 13)+col("model", modelCol(w))+col("effort", 7)+col("score", 7)+col("headroom", 17)+"cost")}
}

func (t Theme) tableRow(c Card, i int, w int) line {
	r := c.Route(i)
	b := badge(r)
	row := line{sg(t.Plain, "  "), sg(t.Badge(b), b),
		sg(t.Plain, " "+col(routeName(r), 13)+col(r.Model, modelCol(w))+col(effortText(r.Effort), 7))}
	scoreSt := t.Plain
	if i == 0 {
		scoreSt = t.Bold
	}
	row = append(row, sg(scoreSt, col(scoreText(r.EffectiveScore), 4)), sg(t.Plain, "   "))
	switch {
	case r.IsGateway():
		host := gatewayHost(r)
		if host == "" {
			host = "gateway"
		}
		row = append(row, sg(t.Badge("GW"), "GW"), sg(t.Dim, " "+col(host, 14)))
	case r.PoolHeadroomPct == nil:
		row = append(row, sg(t.Dim, unknownMeter), sg(t.Dim, " "+unknownText))
	default:
		row = append(row, t.meter(r.PoolHeadroomPct, c.Prog)...)
		row = append(row, sg(t.Plain, " "+fmt.Sprintf("%4s", pctText(r.PoolHeadroomPct))+" "))
	}
	costSt := t.Dim
	if r.CostClass == "free" {
		costSt = t.OK
	}
	row = append(row, sg(costSt, " "+costText(r.CostClass)))
	if i == c.Sel {
		return append(line{sg(t.Accent, "▌")}, row.pad(w-1, t.Plain).on(t.SelBG)...)
	}
	return append(line{sg(t.Plain, " ")}, row...)
}

func (t Theme) hints() line {
	return line{sg(t.Key, " ↵"), sg(t.Dim, " launch  "), sg(t.Key, "↑↓"), sg(t.Dim, " pick  "), sg(t.Key, "tab"), sg(t.Dim, " effort  "),
		sg(t.Key, "w"), sg(t.Dim, " where: "), sg(t.Plain, "here"), sg(t.Dim, "  "), sg(t.Key, "?"), sg(t.Dim, " why  "), sg(t.Key, "esc"), sg(t.Dim, " cancel")}
}

// CardLines is the full route card: box, table and (when hints) key hints.
func (t Theme) CardLines(c Card, width int, hints bool) []line {
	w := boxW(width)
	out := []line{t.promptLine(c.Prompt, width)}
	out = append(out, t.routeBox(c, w)...)
	out = append(out, nil, t.tableHeader(w))
	for i := range c.Rows {
		out = append(out, t.tableRow(c, i, w))
	}
	if hints {
		out = append(out, nil, t.hints())
	}
	return out
}

// CompactLines is the card below 70 columns.
func (t Theme) CompactLines(c Card, width int, hints bool) []line {
	r := c.Route(c.Sel)
	b := badge(r)
	out := []line{t.promptLine(c.Prompt, width)}
	head := line{sg(t.Accent, "▸ "), sg(t.Badge(b), b), sg(t.Bold, " "+routeName(r)), sg(t.Plain, " "+shortModel(r)), sg(t.Dim, " · "), sg(t.Plain, effortText(r.Effort))}
	if c.Yolo {
		head = append(head, sg(t.Plain, " "), t.yoloTag())
	}
	out = append(out, fitLine(head, width))
	pool := "pool " + pctText(r.PoolHeadroomPct)
	if r.IsGateway() {
		pool = "gateway"
	}
	out = append(out, fitLine(line{sg(t.Plain, "  "+scoreText(r.EffectiveScore)), sg(t.Dim, " · "+pool+" · "+costText(r.CostClass))}, width))
	var also []string
	for i := range c.Rows {
		if i != c.Sel {
			o := c.Route(i)
			also = append(also, routeName(o)+" "+scoreText(o.EffectiveScore))
		}
	}
	if len(also) > 0 {
		out = append(out, fitLine(line{sg(t.Dim, "  also: "+strings.Join(also, " · "))}, width))
	}
	if hints {
		out = append(out, fitLine(line{sg(t.Plain, "  "), sg(t.Key, "↵"), sg(t.Dim, " go "), sg(t.Key, "↑↓"), sg(t.Dim, " pick "), sg(t.Key, "?"), sg(t.Dim, " why "), sg(t.Key, "esc")}, width))
	}
	return out
}

// WhyLines is the why panel for the selected row.
func (t Theme) WhyLines(c Card, width int) []line {
	w := boxW(width)
	r := c.Route(c.Sel)
	orig := c.Rows[c.Sel]
	row := func(label string, parts ...seg) line {
		return append(line{sg(t.Dim, "  "+col(label, 15))}, parts...)
	}
	stage := []string{}
	if orig.Stage != "" {
		stage = append(stage, "stage "+orig.Stage)
	}
	if orig.Risk != "" {
		stage = append(stage, "risk "+orig.Risk)
	}
	tc := orig.TaskClass
	if tc == "" {
		tc = unknownText
	}
	taskLine := row("task class", sg(t.Plain, humanize(tc)))
	if len(stage) > 0 {
		taskLine = append(taskLine, sg(t.Dim, "  ("+strings.Join(stage, ", ")+")"))
	}
	bench := orig.BenchmarkName
	if bench == "" {
		bench = unknownText
	}
	synced := ""
	if d, ok := syncedDay(orig.BenchmarkSyncedAt, c.loc()); ok {
		synced = " " + d
	}
	basis := orig.BenchmarkBasis
	if basis == "" {
		basis = "basis " + unknownText
	}
	poolTxt := unknownText + " of 5h window left"
	if orig.PoolHeadroomPct != nil {
		poolTxt = pctText(orig.PoolHeadroomPct) + " of 5h window left"
	}
	if orig.PoolState != "" {
		poolTxt += " (" + orig.PoolState + ")"
	}
	// How the pool figure was found, in a word (the box is narrow).
	switch b := orig.PoolBasis(); {
	case strings.HasPrefix(b, "estimated"):
		poolTxt += " · estimated"
	case strings.HasPrefix(b, "set by"):
		poolTxt += " · failed run"
	case b != "":
		poolTxt += " · " + b
	}
	cost := orig.CostClass
	if cost == "" {
		cost = unknownText
	}
	costNote := ""
	if cost == "subscription" || cost == "free" {
		costNote = "   no pay-per-use spend"
	}
	effort := effortText(r.Effort)
	var effortNote string
	switch {
	case r.Effort != orig.Effort:
		effort = effortText(orig.Effort) + " → " + effortText(r.Effort)
		effortNote = "   you chose it"
	case orig.BaseEffort != "" && orig.BaseEffort != orig.Effort:
		effort = orig.BaseEffort + " → " + effortText(orig.Effort)
		effortNote = "   " + humanize(orig.EffortReason)
	case orig.EffortReason != "":
		effortNote = "   " + humanize(orig.EffortReason)
	}
	eff := unknownText
	if orig.EffectiveScore != nil {
		eff = fmt.Sprintf("%.2f", *orig.EffectiveScore)
	}
	lines := []line{
		taskLine,
		row("benchmark", sg(t.Plain, bench+" "+scoreText(orig.BenchmarkScore)), sg(t.Dim, "   "+basis+synced)),
		row("pool factor", sg(t.Plain, "× "+unknownText), sg(t.Dim, "   "+poolTxt)),
		row("cost class", sg(t.Plain, cost), sg(t.Dim, costNote)),
		row("effort", sg(t.Plain, effort), sg(t.Dim, effortNote)),
		row("effective", sg(t.Plain, eff)),
	}
	if alerts := alertText(orig.AuthAlerts); alerts != "" {
		lines = append(lines, row("sign-in", sg(t.Warn, "! "+alerts)))
	}
	lines = append(lines, nil, line{sg(t.Dim, "  skipped  "), sg(t.Plain, "listed once the engine streams routing events (a later step)")})
	out := []line{t.promptLine(c.Prompt, width), t.top("Why "+routeName(r)+" / "+r.Model, w, t.Border)}
	for _, l := range lines {
		out = append(out, t.boxLine(w, t.Border, l))
	}
	out = append(out, t.bottom(w, t.Border))
	keys := line{sg(t.Key, " ?"), sg(t.Dim, " close   "), sg(t.Key, "e"), sg(t.Dim, " edit prompt   "), sg(t.Key, "y"), sg(t.Dim, " yolo   "), sg(t.Key, "esc"), sg(t.Dim, " cancel")}
	return append(out, fitLine(keys, w))
}

func alertText(a []any) string {
	var parts []string
	for _, x := range a {
		switch v := x.(type) {
		case string:
			parts = append(parts, v)
		default:
			if b, err := json.Marshal(v); err == nil {
				parts = append(parts, string(b))
			}
		}
	}
	return strings.Join(parts, " · ")
}

// ErrorLines is the launch error dialog: red border, what failed, and the
// next-best route on a key.
func (t Theme) ErrorLines(c Card, width int, reason string, next int) []line {
	w := boxW(width)
	r := c.Route(c.Sel)
	out := []line{t.promptLine(c.Prompt, width), t.top("Can't launch "+routeName(r)+" / "+r.Model, w, t.Bad)}
	for _, l := range wrap(reason, w-8) {
		out = append(out, t.boxLine(w, t.Bad, line{sg(t.Plain, "  "+l)}))
	}
	out = append(out, t.boxLine(w, t.Bad, nil))
	out = append(out, t.boxLine(w, t.Bad, line{sg(t.Dim, "  AFK never copies or forwards a plan login.")}))
	out = append(out, t.bottom(w, t.Bad))
	keys := line{sg(t.Key, " r"), sg(t.Dim, " retry  ")}
	if next >= 0 {
		n := c.Route(next)
		keys = append(keys, sg(t.Key, "↵"), sg(t.Dim, " use next best ("+routeName(n)+" / "+n.Model+")  "))
	}
	keys = append(keys, sg(t.Key, "esc"), sg(t.Dim, " cancel"))
	return append(out, fitLine(keys, max(width, 1)))
}

// RouteErrorLines is the error dialog when routing itself failed (the
// engine did not answer in time): there is no route to fall back to.
func (t Theme) RouteErrorLines(prompt string, width int, reason string) []line {
	w := boxW(width)
	out := []line{t.promptLine(prompt, width), t.top("Can't route this task", w, t.Bad)}
	for _, l := range wrap(reason, w-8) {
		out = append(out, t.boxLine(w, t.Bad, line{sg(t.Plain, "  "+l)}))
	}
	out = append(out, t.boxLine(w, t.Bad, nil), t.boxLine(w, t.Bad, line{sg(t.Dim, "  Nothing was started.")}), t.bottom(w, t.Bad))
	return append(out, fitLine(line{sg(t.Key, " r"), sg(t.Dim, " retry  "), sg(t.Key, "esc"), sg(t.Dim, " cancel")}, max(width, 1)))
}

// LaunchLine is the receipt line printed when the CLI starts:
// ▸ CL claude · claude-fable-5-2 · high · here    run r-7f3c
func (t Theme) LaunchLine(r engine.Route, where, id string, yolo bool, width int) line {
	b := badge(r)
	l := line{sg(t.Accent, "▸ "), sg(t.Badge(b), b), sg(t.Bold, " "+routeName(r)), sg(t.Dim, " · "+r.Model+" · "+effortText(r.Effort)+" · "+where)}
	if yolo {
		l = append(l, sg(t.Plain, "  "), t.yoloTag())
	}
	tail := "run " + id
	gap := 70 - l.width() - lenCells(tail)
	if gap < 2 {
		gap = 2
	}
	l = append(l, sg(t.Dim, strings.Repeat(" ", gap)+tail))
	if width > 0 {
		l = fitLine(l, width)
	}
	return l
}

// SessionRule is printed just before the CLI takes the terminal.
func (t Theme) SessionRule(r engine.Route) line {
	b := badge(r)
	label := " " + routeName(r) + " session "
	right := 45 - lenCells(label) // the rule is 77 cells wide
	return line{sg(t.Dim, "  "+strings.Repeat("─", 27)+" "), sg(t.Badge(b), b), sg(t.Dim, label+strings.Repeat("─", max(right, 3)))}
}

// EndRule closes the session in scrollback.
func (t Theme) EndRule() line { return line{sg(t.Dim, "  "+strings.Repeat("─", 74))} }
