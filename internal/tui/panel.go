package tui

import (
	"context"
	"fmt"
	"math"
	"os/exec"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// The control panel: full-screen management tabs across the top (Route,
// Harnesses, Benchmarks, Skills, MCP, Runs, Config). 1–7 switch tabs; Route
// goes back to the composer.

// Tab is one of the panel's tabs.
type Tab int

// The tabs, in the order the tab bar shows them.
const (
	TabRoute Tab = iota
	TabHarnesses
	TabBench
	TabSkills
	TabMCP
	TabRuns
	TabConfig
)

var tabNames = []string{"Route", "Harnesses", "Benchmarks", "Skills", "MCP", "Runs", "Config"}

// TabFor is the tab a slash command or `afk <command>` names.
func TabFor(name string) (Tab, bool) {
	switch strings.ToLower(strings.TrimPrefix(name, "/")) {
	case "route":
		return TabRoute, true
	case "harness", "harnesses":
		return TabHarnesses, true
	case "bench", "benchmarks":
		return TabBench, true
	case "skills":
		return TabSkills, true
	case "mcp":
		return TabMCP, true
	case "runs", "status":
		return TabRuns, true
	case "config":
		return TabConfig, true
	}
	return 0, false
}

// PanelSource is where the tabs' data comes from. Each call may be slow
// (CLIs are asked for their versions, pools are probed); the panel shows
// "loading" meanwhile.
type PanelSource interface {
	Harnesses(ctx context.Context) (*HarnessesView, error)
	Benchmarks(ctx context.Context, task string) (*BenchView, error)
	Status(ctx context.Context) (*StatusView, error)
	Config(ctx context.Context) (*ConfigView, error)
	// Command is the argv that runs an afk subcommand (an update, a
	// login, a sync) in the terminal, for the tabs' action keys.
	Command(args ...string) []string
}

// HarnessesView is the Harnesses tab.
type HarnessesView struct {
	Rows []HarnessRow
}

// HarnessRow is one CLI.
type HarnessRow struct {
	Name, Display, Version string
	Installed              bool
	SignIn                 string // "Claude Ultra", "signed out", "unknown"
	Routes                 string // plan, gateway, plan+gw, local, —
	Update                 string // the command that updates it ("" none)
	Path, Method           string
	Models                 []string
	Usage                  string // "5h 71% left · week 64% left"
	Note                   string // the sign-in note, a problem
}

// BenchView is the Benchmarks tab for one task kind.
type BenchView struct {
	Task     string
	Source   string // "LMArena Code · synced 2026-11-27"
	Rows     []BenchRow
	Routes   []engine.Route // the best route on each CLI, for "Effective today"
	Problems string
}

// BenchRow is one model.
type BenchRow struct {
	Model                 string
	Via                   []engine.Route // the routes that serve it (for logos)
	Score                 *float64
	Basis                 string
	Solved, Partly, Wrong int
}

// StatusView is the Runs tab (and `afk status`).
type StatusView struct {
	Updated time.Time
	Plans   []PlanRow
	Gateway *GatewayRow
	Engines []EngineRow
	Runs    []RunRow
}

// PlanRow is one plan pool.
type PlanRow struct {
	Harness, Plan string
	FiveHour      *float64 // headroom %
	Week          *float64
	SignIn        string
	Note          string
}

// GatewayRow is the model gateway.
type GatewayRow struct {
	Name, Kind, State, Detail string
	Engine, EngineHost        string
}

// EngineRow is a local engine.
type EngineRow struct {
	Engine, State, Where string
	Models               []string
}

// RunRow is one recorded session.
type RunRow struct {
	ID, Where, CLI, Model, Outcome string
	Exit                           int
	Started                        time.Time
	Duration                       time.Duration
}

// ConfigView is the Config tab: the effective settings and where they
// come from.
type ConfigView struct {
	Path     string
	Exists   bool
	Rows     [][2]string // key, value
	Warnings []string
}

type panelData struct {
	harn   *HarnessesView
	bench  *BenchView
	status *StatusView
	config *ConfigView
	err    map[Tab]string
}

type panelMsg struct {
	panel int // the opening it belongs to
	tab   Tab
	gen   int
	v    any
	err  error
	task string
}

type panelExecMsg struct {
	panel int
	err   error
}

// panelIDs numbers each opening of the panel, so a load started by one
// that was closed never reaches the next.
var panelIDs int

// Panel is the full-screen tabs. It runs on its own (`afk status`) or
// inside the card's Model (from the composer).
type Panel struct {
	src     PanelSource
	theme   Theme
	tab     Tab
	width   int
	height  int
	sel     map[Tab]int
	taskIdx int
	data    panelData
	id      int
	gens    map[Tab]int // the latest load of each tab
	loading map[Tab]bool
	notice  string
	ctx     context.Context
	stop    context.CancelFunc
	now     func() time.Time
	version string
	// standalone: Route quits rather than going back to a composer.
	standalone bool
	quit       bool
	back       bool
}

// NewPanel opens the panel on a tab.
func NewPanel(ctx context.Context, src PanelSource, theme Theme, tab Tab, version string, now func() time.Time) *Panel {
	if now == nil {
		now = time.Now
	}
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, stop := context.WithCancel(ctx)
	panelIDs++
	return &Panel{id: panelIDs, gens: map[Tab]int{}, src: src, theme: theme, tab: tab, sel: map[Tab]int{}, loading: map[Tab]bool{},
		data: panelData{err: map[Tab]string{}}, ctx: ctx, stop: stop, now: now, version: version}
}

// Close stops the loads still running.
func (p *Panel) Close() { p.stop() }

// Standalone makes Route (1) and q end the program: `afk status`.
func (p *Panel) Standalone() *Panel { p.standalone = true; return p }

// benchTasks are the task kinds the Benchmarks tab steps through.
var benchTasks = []string{"coding", "quick", "complex", "review", "architecture", "webdev", "research", "security"}

func (p *Panel) Init() tea.Cmd { return p.load(p.tab) }

// load fetches a tab's data in the background.
func (p *Panel) load(tab Tab) tea.Cmd {
	if p.src == nil {
		return nil
	}
	p.gens[tab]++
	gen, id, src, ctx := p.gens[tab], p.id, p.src, p.ctx
	p.loading[tab] = true
	task := benchTasks[p.taskIdx%len(benchTasks)]
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		var v any
		var err error
		switch tab {
		case TabHarnesses:
			v, err = src.Harnesses(ctx)
		case TabBench:
			v, err = src.Benchmarks(ctx, task)
		case TabRuns:
			v, err = src.Status(ctx)
		case TabConfig:
			v, err = src.Config(ctx)
		default:
			return panelMsg{panel: id, tab: tab, gen: gen}
		}
		return panelMsg{panel: id, tab: tab, gen: gen, v: v, err: err, task: task}
	}
}

// Update handles a message. It returns whether the panel is done (back
// to the composer, or quit).
func (p *Panel) Update(msg tea.Msg) tea.Cmd {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		p.width, p.height = msg.Width, msg.Height
	case panelMsg:
		if msg.panel != p.id || msg.gen != p.gens[msg.tab] {
			return nil // a newer load of this tab is on its way
		}
		p.loading[msg.tab] = false
		if msg.err != nil {
			p.data.err[msg.tab] = msg.err.Error()
			return nil
		}
		delete(p.data.err, msg.tab)
		switch v := msg.v.(type) {
		case *HarnessesView:
			p.data.harn = v
		case *BenchView:
			if msg.task == benchTasks[p.taskIdx%len(benchTasks)] {
				p.data.bench = v
			}
		case *StatusView:
			p.data.status = v
		case *ConfigView:
			p.data.config = v
		}
	case panelExecMsg:
		if msg.panel != p.id {
			return nil
		}
		if msg.err != nil {
			p.notice = msg.err.Error()
		}
		return p.load(p.tab)
	case tea.KeyPressMsg:
		return p.key(msg.String())
	}
	return nil
}

func (p *Panel) key(k string) tea.Cmd {
	p.notice = ""
	switch k {
	case "q", "ctrl+c":
		p.quit = true
		return nil
	case "esc":
		if p.standalone {
			p.quit = true
		} else {
			p.back = true
		}
		return nil
	case "1", "2", "3", "4", "5", "6", "7":
		return p.switchTo(Tab(k[0] - '1'))
	case "tab":
		return p.switchTo(Tab((int(p.tab) + 1) % len(tabNames)))
	case "shift+tab":
		return p.switchTo(Tab((int(p.tab) + len(tabNames) - 1) % len(tabNames)))
	case "up", "k":
		if p.sel[p.tab] > 0 {
			p.sel[p.tab]--
		}
		return nil
	case "down", "j":
		if p.sel[p.tab] < p.rows()-1 {
			p.sel[p.tab]++
		}
		return nil
	case "r":
		return p.load(p.tab)
	}
	switch p.tab {
	case TabHarnesses:
		if p.data.harn == nil || len(p.data.harn.Rows) == 0 {
			return nil
		}
		h := p.data.harn.Rows[min(p.sel[p.tab], len(p.data.harn.Rows)-1)]
		switch k {
		case "u":
			if h.Update == "" {
				p.notice = h.Name + " has no update command AFK knows"
				return nil
			}
			return p.run("harness", "update", h.Name)
		case "l":
			return p.run("harness", "login", h.Name)
		case "d":
			return p.run("harness", "doctor", h.Name)
		}
	case TabBench:
		switch k {
		case "left", "h":
			p.taskIdx = (p.taskIdx + len(benchTasks) - 1) % len(benchTasks)
			p.sel[p.tab] = 0
			return p.load(TabBench)
		case "right", "l":
			p.taskIdx = (p.taskIdx + 1) % len(benchTasks)
			p.sel[p.tab] = 0
			return p.load(TabBench)
		case "s":
			return p.run("bench", "sync")
		}
	case TabConfig:
		if k == "e" {
			return p.run("config", "edit")
		}
	}
	return nil
}

// run hands the terminal to an afk subcommand, then reloads the tab.
func (p *Panel) run(args ...string) tea.Cmd {
	if p.src == nil {
		return nil
	}
	argv := p.src.Command(args...)
	if len(argv) == 0 {
		return nil
	}
	c := exec.Command(argv[0], argv[1:]...)
	id := p.id
	return tea.ExecProcess(c, func(err error) tea.Msg { return panelExecMsg{panel: id, err: err} })
}

func (p *Panel) switchTo(t Tab) tea.Cmd {
	if int(t) < 0 || int(t) >= len(tabNames) {
		return nil
	}
	if t == TabRoute {
		if p.standalone {
			p.quit = true
		} else {
			p.back = true
		}
		return nil
	}
	p.tab = t
	if p.loaded(t) {
		return nil
	}
	return p.load(t)
}

func (p *Panel) loaded(t Tab) bool {
	switch t {
	case TabHarnesses:
		return p.data.harn != nil
	case TabBench:
		// Only the selected task's scores: another task's would show
		// under the wrong label while the new one loads.
		return p.data.bench != nil && p.data.bench.Task == benchTasks[p.taskIdx%len(benchTasks)]
	case TabRuns:
		return p.data.status != nil
	case TabConfig:
		return p.data.config != nil
	}
	return true
}

// rows is how many selectable rows the tab has.
func (p *Panel) rows() int {
	switch p.tab {
	case TabHarnesses:
		if p.data.harn != nil {
			return len(p.data.harn.Rows)
		}
	case TabBench:
		if p.data.bench != nil {
			return len(p.data.bench.Rows)
		}
	case TabRuns:
		if p.data.status != nil {
			return len(p.data.status.Runs)
		}
	case TabConfig:
		if p.data.config != nil {
			return len(p.data.config.Rows)
		}
	}
	return 0
}

// Lines is the panel as lines: the tab bar, the tab, the key hints.
func (p *Panel) Lines() []line {
	t := p.theme
	w := p.width
	if w <= 0 {
		w = 80
	}
	out := []line{p.tabBar(w), nil}
	var body []line
	var hint line
	switch {
	case p.data.err[p.tab] != "":
		body = []line{{sg(t.Warn, " ! "+p.data.err[p.tab])}, nil, {sg(t.Dim, " r to try again")}}
	case !p.loaded(p.tab):
		body = []line{{sg(t.Dim, " loading…")}}
	}
	if body == nil {
		switch p.tab {
		case TabHarnesses:
			body, hint = p.harnessLines(w)
		case TabBench:
			body, hint = p.benchLines(w)
		case TabSkills, TabMCP:
			body, hint = p.comingLines()
		case TabRuns:
			body, hint = p.statusLines(w)
		case TabConfig:
			body, hint = p.configLines(w)
		}
	}
	if p.height > 0 {
		// The tab bar and its gap, the notice and the hints keep their
		// rows; the body scrolls to keep the selected row in view.
		room := p.height - len(out) - 1
		if p.notice != "" {
			room -= 2
		}
		body = scrollTo(body, max(room, 1))
	}
	for _, l := range body {
		out = append(out, fitLine(l, w))
	}
	if p.notice != "" {
		out = append(out, nil, fitLine(line{sg(t.Warn, " "+p.notice)}, w))
	}
	// The hints sit on the last row when the height is known.
	if p.height > 0 {
		for len(out) < p.height-1 {
			out = append(out, nil)
		}
	} else {
		out = append(out, nil)
	}
	keys := line{sg(t.Plain, " ")}
	keys = append(keys, hint...)
	keys = append(keys, sg(t.Key, "1-7"), sg(t.Dim, " tabs  "), sg(t.Key, "r"), sg(t.Dim, " refresh  "), sg(t.Key, "q"), sg(t.Dim, " quit"))
	return append(out, fitLine(keys, w))
}

// View is the panel full screen.
func (p *Panel) View() tea.View {
	v := tea.NewView(join(p.Lines()))
	v.AltScreen = true
	return v
}

// scrollTo cuts body to n lines, moving the window down far enough to
// show the selected row (the one selRow marks with ▌).
func scrollTo(body []line, n int) []line {
	if len(body) <= n {
		return body
	}
	sel := -1
	for i, l := range body {
		if len(l) > 0 && l[0].s == "▌" {
			sel = i
		}
	}
	start := 0
	if sel >= n {
		start = min(sel-n+2, len(body)-n) // one row of what follows, when there is one
	}
	return body[start : start+n]
}

func (p *Panel) tabBar(w int) line {
	t := p.theme
	// Every label, when they fit; else numbers, with the open tab named.
	full := 1
	for _, n := range tabNames {
		full += lenCells(n) + 3
	}
	l := line{sg(t.Plain, " ")}
	for i, n := range tabNames {
		if Tab(i) == p.tab {
			if full > w {
				n = fmt.Sprintf("%d %s", i+1, n)
			}
			l = append(l, sg(t.Accent.Bold(true).Background(t.selbg), " "+n+" "))
		} else {
			if full > w {
				n = fmt.Sprint(i + 1)
			}
			l = append(l, sg(t.Dim, " "+n+" "))
		}
		l = append(l, sg(t.Plain, " "))
	}
	if v := p.version; v != "" {
		right := "afk " + v
		if gap := w - l.width() - lenCells(right) - 1; gap > 1 {
			l = append(l, sg(t.Plain, strings.Repeat(" ", gap)), sg(t.Dim, right))
		}
	}
	return l
}

// selRow highlights the selected row the way the route table does.
func (p *Panel) selRow(l line, i, w int) line {
	t := p.theme
	if i == p.sel[p.tab] {
		return append(line{sg(t.Accent, "▌")}, l.pad(w-1, t.Plain).on(t.SelBG)...)
	}
	return append(line{sg(t.Plain, " ")}, l...)
}

func harnessLogo(t Theme, name string) seg { return t.logo(engine.Route{Harness: name}) }

func (p *Panel) harnessLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.harn
	var out []line
	if len(v.Rows) == 0 {
		return []line{{sg(t.Dim, " No agent CLI found on this machine. Install claude, codex, grok, opencode, agy or pi.")}}, nil
	}
	out = append(out, line{sg(t.Dim, "   "+col("harness", 13)+col("version", 9)+col("sign-in", 15)+col("routes", 9)+"update")})
	for i, h := range v.Rows {
		ver, sign, routes, upd := h.Version, h.SignIn, h.Routes, "·"
		if ver == "" {
			ver = unknownText
		}
		if !h.Installed {
			ver, sign, routes = "—", "not installed", "—"
		}
		if h.Update != "" && h.Installed {
			upd = "u"
		}
		st := t.Plain
		if !h.Installed {
			st = t.Dim
		}
		signSt := t.Plain
		switch {
		case strings.Contains(sign, "signed out") || strings.Contains(sign, "expired"):
			signSt = t.Warn
		case sign == "unknown" || !h.Installed:
			signSt = t.Dim
		}
		row := line{sg(t.Plain, " "), harnessLogo(t, h.Name), sg(st, " "+col(h.Name, 10)), sg(st, col(ver, 9)), sg(signSt, col(sign, 15)), sg(st, col(routes, 9)), sg(t.Dim, upd)}
		out = append(out, p.selRow(row, i, w))
	}
	h := v.Rows[min(p.sel[p.tab], len(v.Rows)-1)]
	out = append(out, nil)
	head := line{sg(t.Plain, " "), harnessLogo(t, h.Name), sg(t.Bold, " "+h.Name)}
	if h.Path != "" {
		head = append(head, sg(t.Dim, " · "+h.Path))
	}
	if h.Method != "" {
		head = append(head, sg(t.Dim, " · "+h.Method))
	}
	out = append(out, head)
	if h.Note != "" {
		out = append(out, line{sg(t.Dim, "   "+h.Note)})
	}
	if len(h.Models) > 0 {
		out = append(out, line{sg(t.Dim, "   models  "), sg(t.Plain, strings.Join(h.Models, ", "))})
	}
	if h.Usage != "" {
		out = append(out, line{sg(t.Dim, "   usage   "), sg(t.Plain, h.Usage)})
	}
	if h.Update != "" {
		out = append(out, line{sg(t.Dim, "   update  "), sg(t.Plain, h.Update)})
	}
	hint := line{sg(t.Key, "↑↓"), sg(t.Dim, " pick  "), sg(t.Key, "u"), sg(t.Dim, " update  "), sg(t.Key, "l"), sg(t.Dim, " login  "), sg(t.Key, "d"), sg(t.Dim, " doctor  ")}
	return out, hint
}

// scoreBar is a score out of 100 as a 10-cell bar with eighth blocks.
func scoreBar(score float64) string {
	// 10 cells hold 84.4 points, as the design's bars do, so the top of
	// the board fills most of the bar.
	eighths := int(math.Round(math.Max(0, math.Min(84.4, score)) * 80 / 84.4))
	full, part := eighths/8, eighths%8
	s := strings.Repeat("█", full)
	if part > 0 {
		s += string([]rune("▏▎▍▌▋▊▉")[part-1])
	}
	return s
}

func (p *Panel) benchLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.bench
	cur := benchTasks[p.taskIdx%len(benchTasks)]
	tasks := line{sg(t.Dim, " task   ")}
	for _, k := range benchTasks {
		if k == cur {
			tasks = append(tasks, sg(t.Accent.Bold(true), k), sg(t.Plain, "  "))
		} else {
			tasks = append(tasks, sg(t.Dim, k+"  "))
		}
	}
	out := []line{tasks}
	if v.Source != "" {
		out = append(out, line{sg(t.Dim, " source "), sg(t.Plain, v.Source), sg(t.Dim, " · "), sg(t.Key, "s"), sg(t.Dim, " sync now")})
	}
	out = append(out, nil, line{sg(t.Dim, "   "+col("model", 19)+col("via", 12)+col("score", 19)+col("basis", 10)+"your runs")})
	for i, r := range v.Rows {
		via := line{}
		for j, x := range r.Via {
			if j > 0 {
				via = append(via, sg(t.Plain, " "))
			}
			via = append(via, t.logo(x))
		}
		pad := 12 - via.width()
		if pad < 1 {
			pad = 1
		}
		score := unknownText
		bar := ""
		if r.Score != nil {
			score = fmt.Sprintf("%.1f", *r.Score)
			bar = scoreBar(*r.Score)
		}
		basisSt := t.Plain
		if r.Basis == "estimate" || r.Basis == "stale" {
			basisSt = t.Dim
		}
		runs := "—"
		if r.Solved+r.Partly+r.Wrong > 0 {
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
			runs = strings.Join(parts, " ")
		}
		row := line{sg(t.Plain, "  "+col(r.Model, 19))}
		row = append(row, via...)
		row = append(row, sg(t.Plain, strings.Repeat(" ", pad)), sg(t.Accent, col(bar, 12)), sg(t.Plain, fmt.Sprintf("%5s", score)+"  "), sg(basisSt, col(r.Basis, 10)), sg(t.Plain, runs))
		out = append(out, p.selRow(row, i, w))
	}
	if len(v.Rows) == 0 {
		out = append(out, line{sg(t.Dim, "   no model in the catalog is scored on "+cur)})
	}
	if len(v.Routes) > 0 {
		out = append(out, nil, line{sg(t.Plain, " Effective today"), sg(t.Dim, "  score × plan headroom × cost")})
		eff := line{sg(t.Plain, " ")}
		for _, r := range v.Routes {
			s := unknownText
			if r.EffectiveScore != nil {
				s = fmt.Sprintf("%.1f", *r.EffectiveScore)
			}
			eff = append(eff, t.logo(r), sg(t.Plain, " "+s))
			if r.PoolHeadroomPct != nil && *r.PoolHeadroomPct < 100 && !r.IsLocal() && !r.IsGateway() {
				eff = append(eff, sg(t.Dim, " ("+pctText(r.PoolHeadroomPct)+")"))
			}
			eff = append(eff, sg(t.Plain, "   "))
		}
		out = append(out, eff)
	}
	if v.Problems != "" {
		out = append(out, nil, line{sg(t.Warn, " "+v.Problems)})
	}
	out = append(out, nil,
		line{sg(t.Dim, " estimate = catalog figure, not measured · capped = board doesn't list it")},
		line{sg(t.Dim, " your runs = your 1/2/3 ratings: ✓ solved  ~ partly  ✗ wrong pick")})
	hint := line{sg(t.Key, "←→"), sg(t.Dim, " task  "), sg(t.Key, "s"), sg(t.Dim, " sync  ")}
	return out, hint
}

func (p *Panel) comingLines() ([]line, line) {
	t := p.theme
	what := map[Tab]string{
		TabSkills: "Skills: one central copy of every skill, synced into each CLI, with drift shown per CLI.",
		TabMCP:    "MCP: your MCP servers, written into each CLI's own config, with a tools/list health check.",
	}[p.tab]
	return []line{{sg(t.Plain, " "+what)}, nil, {sg(t.Dim, " Not built yet: it comes with AFK's skills and MCP sync.")}}, nil
}

func (p *Panel) statusLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.status
	out := []line{}
	if !v.Updated.IsZero() {
		out = append(out, line{sg(t.Dim, " updated "+v.Updated.Format("15:04")+" · "), sg(t.Key, "r"), sg(t.Dim, " refresh")}, nil)
	}
	out = append(out, line{sg(t.Bold, " Plans"), sg(t.Dim, strings.Repeat(" ", 17)+col("5h window", 19)+col("week", 19)+"sign-in")})
	cell := func(pct *float64) line {
		l := append(t.meter(pct, 1), sg(t.Plain, " "+pctText(pct)))
		return append(l, sg(t.Plain, strings.Repeat(" ", max(1, 19-l.width()))))
	}
	for _, pl := range v.Plans {
		row := line{sg(t.Plain, " "), harnessLogo(t, pl.Harness), sg(t.Plain, " "+col(pl.Plan, 19))}
		row = append(row, cell(pl.FiveHour)...)
		row = append(row, cell(pl.Week)...)
		signSt := t.OK
		if pl.SignIn != "ok" {
			signSt = t.Warn
		}
		row = append(row, sg(signSt, pl.SignIn))
		out = append(out, row)
		if pl.Note != "" {
			out = append(out, line{sg(t.Dim, "   "+pl.Note)})
		}
	}
	if v.Gateway != nil || len(v.Engines) > 0 {
		out = append(out, nil, line{sg(t.Bold, " Gateway and local engines")})
	}
	if g := v.Gateway; g != nil {
		r := engine.Route{LaunchClass: "claude-gateway", GatewayKind: g.Kind}
		st := t.OK
		if g.State != "up" {
			st = t.Warn
		}
		out = append(out, line{sg(t.Plain, " "), t.logo(r), sg(t.Plain, " "+col(g.Name, 18)), sg(st, col(g.State, 10)), sg(t.Dim, g.Detail)})
		if g.Engine != "" {
			out = append(out, line{sg(t.Dim, "   └ "), t.engineLogo(g.Engine), sg(t.Plain, " "+col(engineName(g.Engine), 14)), sg(t.Dim, g.EngineHost)})
		}
	}
	for _, e := range v.Engines {
		st := t.OK
		if e.State == "" {
			e.State = unknownText
			st = t.Dim
		}
		detail := e.Where
		if len(e.Models) > 0 {
			detail += " · " + plural(len(e.Models), "model", "models")
		}
		out = append(out, line{sg(t.Plain, " "), t.engineLogo(e.Engine), sg(t.Plain, " "+col(e.Engine, 18)), sg(st, col(e.State, 10)), sg(t.Dim, detail)})
	}
	out = append(out, nil, line{sg(t.Bold, " Runs"), sg(t.Dim, strings.Repeat(" ", 27)+col("where", 10)+col("CLI", 10)+col("state", 13)+"time")})
	if len(v.Runs) == 0 {
		out = append(out, line{sg(t.Dim, "   no runs yet: they are recorded when a session started from the card ends")})
	}
	now := p.now()
	for i, r := range v.Runs {
		state, st := "● done", t.OK
		switch {
		case r.Exit != 0:
			state, st = fmt.Sprintf("! exit %d", r.Exit), t.Warn
		case r.Outcome == "wrong-pick":
			state, st = "✗ wrong pick", t.Warn
		case r.Outcome == "partly":
			state, st = "~ partly", t.Plain
		case r.Outcome == "solved":
			state = "✓ solved"
		}
		when := ""
		if !r.Started.IsZero() {
			when = " · " + ago(now.Sub(r.Started)) + " ago"
		}
		row := line{sg(t.Dim, " "+col(r.ID, 8)), sg(t.Plain, col(r.Model, 22)), sg(t.Plain, col(r.Where, 10)), sg(t.Plain, col(r.CLI, 10)), sg(st, col(state, 13)), sg(t.Dim, ago(r.Duration)+when)}
		out = append(out, p.selRow(row, i, w))
	}
	return out, nil
}

// ago is a rough age: 5m, 3h, 2d.
func ago(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d/time.Second))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d/time.Minute))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d/time.Hour))
	}
	return fmt.Sprintf("%dd", int(d/(24*time.Hour)))
}

func (p *Panel) configLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.config
	head := line{sg(t.Dim, " file "), sg(t.Plain, v.Path)}
	if !v.Exists {
		head = append(head, sg(t.Dim, " (not created yet: defaults apply; "), sg(t.Key, "e"), sg(t.Dim, " creates it)"))
	}
	out := []line{head, nil, {sg(t.Dim, "   "+col("setting", 28)+"value")}}
	for i, kv := range v.Rows {
		out = append(out, p.selRow(line{sg(t.Plain, "  "+col(kv[0], 28)), sg(t.Plain, kv[1])}, i, w))
	}
	for _, wn := range v.Warnings {
		out = append(out, fitLine(line{sg(t.Warn, " ! "+wn)}, w))
	}
	hint := line{sg(t.Key, "e"), sg(t.Dim, " edit config.toml  ")}
	return out, hint
}

// PanelModel runs a Panel as a program of its own (`afk status`).
type PanelModel struct{ P *Panel }

func (m PanelModel) Init() tea.Cmd { return m.P.Init() }

func (m PanelModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	cmd := m.P.Update(msg)
	if m.P.quit || m.P.back {
		return m, tea.Quit
	}
	return m, cmd
}

func (m PanelModel) View() tea.View { return m.P.View() }
