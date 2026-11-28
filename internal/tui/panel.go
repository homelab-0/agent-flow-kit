package tui

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"
	"unicode/utf8"

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
	// ConfigSet writes one setting to the user's config file and returns
	// what to tell the user.
	ConfigSet(ctx context.Context, key, value string) (string, error)
	// ConfigRemove takes a section (such as gateway.work) out of the
	// config file.
	ConfigRemove(ctx context.Context, section string) (string, error)
	Skills(ctx context.Context) (*SkillsView, error)
	// SkillsDo runs a quick skills action in place (sync, keep, restore,
	// enable, disable) and returns what to tell the user.
	SkillsDo(ctx context.Context, op string, args ...string) (string, error)
	MCP(ctx context.Context) (*MCPView, error)
	// MCPDo runs an MCP action in place (sync, test, keep, restore,
	// enable, disable) and returns what to tell the user.
	MCPDo(ctx context.Context, op string, args ...string) (string, error)
	// MCPTools connects to a server, lists its tools and records the
	// result as a test.
	MCPTools(ctx context.Context, server string) ([]MCPTool, error)
	// ClearMarks removes every failed-run mark that set a plan aside and
	// returns what to tell the user.
	ClearMarks(ctx context.Context) (string, error)
	// Command is the argv that runs an afk subcommand (an update, a
	// login, a sync) in the terminal, for the tabs' action keys.
	Command(args ...string) []string
}

// HarnessesView is the Harnesses tab.
type HarnessesView struct {
	Rows []HarnessRow
	// AutoDiscover is discovery.auto: AFK asks each CLI again when its
	// last answer is five minutes old.
	AutoDiscover bool
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
	// NoFiveHour and NoWeek say the plan's CLI listed its limits and this
	// one isn't among them: the plan has no such limit, which is not the
	// same as a figure AFK doesn't know.
	NoFiveHour, NoWeek bool
	SignIn             string
	Note               string
	// SetAside says a failed run set this plan aside (Note says why and
	// for how long); c on the tab clears it.
	SetAside bool
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
	// Edit says how a row is changed from the tab, by its key. A row
	// without an entry is shown only.
	Edit map[string]ConfigEdit
}

// ConfigEdit is how the Config tab changes one setting.
type ConfigEdit struct {
	// Choices are the values enter steps through; nil means the value is
	// typed.
	Choices []string
	// Value is what the input starts with when the value is typed, and
	// Hint what is said beside it.
	Value, Hint string
	// Remove, when set, is the section x takes out of the file (the
	// gateway this row belongs to).
	Remove string
	// Confirm, when set, is asked before a switch is turned on: what it
	// does and what it risks. Enter then turns it on; turning it off
	// asks nothing.
	Confirm string
}

type panelData struct {
	harn   *HarnessesView
	bench  *BenchView
	status *StatusView
	config *ConfigView
	skills *SkillsView
	mcp    *MCPView
	err    map[Tab]string
}

type panelMsg struct {
	panel int // the opening it belongs to
	tab   Tab
	gen   int
	v     any
	err   error
	task  string
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
	// skillCol is the selected CLI column on the Skills tab.
	skillCol int
	mcpCol   int
	askScope string    // the project skill or server whose scope is being asked
	data     panelData // what the tabs show: raw, narrowed by the filter
	raw      panelData // what was loaded
	filter   map[Tab]string
	typing   bool       // the filter is being typed
	tools    *toolsView // a server's tools, open over the MCP tab
	toolsGen int        // the latest tools listing
	// A setting's value being typed on the Config tab.
	cfgKey, cfgText, cfgHint string
	cfgRemove                string // the section x was pressed on once
	// A switch waiting for its yes: the key, and what is asked.
	cfgAskKey, cfgAsk string
	ask               *panelAsk
	pal               *palette // the command palette, when open
	id                int
	gens              map[Tab]int // the latest load of each tab
	loading           map[Tab]bool
	notice            string
	ctx               context.Context
	stop              context.CancelFunc
	now               func() time.Time
	version           string
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
		data: panelData{err: map[Tab]string{}}, filter: map[Tab]string{}, ctx: ctx, stop: stop, now: now, version: version}
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
		case TabSkills:
			v, err = src.Skills(ctx)
		case TabMCP:
			v, err = src.MCP(ctx)
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
			p.raw.harn = v
		case *BenchView:
			if msg.task == benchTasks[p.taskIdx%len(benchTasks)] {
				p.raw.bench = v
			}
		case *StatusView:
			p.raw.status = v
		case *ConfigView:
			sortConfig(v)
			p.raw.config = v
		case *SkillsView:
			p.raw.skills = v
			if len(v.Cols) > 0 {
				p.skillCol = min(p.skillCol, len(v.Cols)-1)
			}
		case *MCPView:
			p.raw.mcp = v
			if len(v.Cols) > 0 {
				p.mcpCol = min(p.mcpCol, len(v.Cols)-1)
			}
		}
		p.refilter(msg.tab)
	case mcpToolsMsg:
		if msg.panel != p.id || msg.gen != p.toolsGen {
			return nil // a newer listing replaced this one
		}
		if msg.err != nil {
			p.notice = msg.err.Error()
		} else {
			p.notice = ""
			p.tools = &toolsView{server: msg.server, tools: msg.tools}
		}
		return p.load(TabMCP) // the test updated its tool count and status
	case mcpDoneMsg:
		p.notice = msg.text
		if msg.err != nil {
			p.notice = msg.err.Error()
		}
		return p.load(TabMCP)
	case configSavedMsg:
		p.notice = msg.text
		if msg.err != nil {
			p.notice = "not saved: " + msg.err.Error()
		}
		if p.tab != TabConfig {
			return tea.Batch(p.load(TabConfig), p.load(p.tab))
		}
		return p.load(TabConfig)
	case marksClearedMsg:
		p.notice = msg.text
		if msg.err != nil {
			p.notice = msg.err.Error()
		}
		return p.load(TabRuns)
	case skillsDoneMsg:
		p.notice = msg.text
		if msg.err != nil {
			p.notice = msg.err.Error()
		}
		return p.load(TabSkills)
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
	if p.pal != nil {
		return p.palKey(k)
	}
	if p.askScope != "" && p.tab == TabSkills {
		return p.skillsKey(k) // the scope question takes the next key
	}
	if p.askScope != "" && p.tab == TabMCP {
		return p.mcpKey(k)
	}
	if p.cfgKey != "" {
		return p.configTyping(k)
	}
	if p.cfgAskKey != "" {
		key := p.cfgAskKey
		p.cfgAskKey, p.cfgAsk = "", ""
		if k == "enter" || k == "y" {
			return p.configSave(key, "on")
		}
		p.notice = key + " left off"
		return nil
	}
	if p.ask != nil {
		return p.askKey(k)
	}
	armed := p.cfgRemove
	p.cfgRemove = ""
	if p.filterKey(k) {
		return nil
	}
	if k == "ctrl+p" || k == ":" {
		p.pal = &palette{}
		p.tools = nil
		return nil
	}
	if p.tools != nil && p.tab == TabMCP {
		switch k {
		case "1", "2", "3", "4", "5", "6", "7", "tab", "shift+tab":
			p.tools = nil // the tab keys still change tabs
		default:
			return p.toolsKey(k)
		}
	}
	switch k {
	case "/":
		if filterable(p.tab) {
			p.typing = true
			return nil
		}
	case "esc":
		if p.filter[p.tab] != "" { // esc clears a filter before it leaves
			p.setFilter("")
			return nil
		}
	}
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
	case "k":
		if p.tab == TabSkills {
			return p.skillsKey(k) // k keeps a CLI's copy there
		}
		if p.tab == TabMCP {
			return p.mcpKey(k)
		}
		fallthrough
	case "up":
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
	if p.tab == TabSkills {
		return p.skillsKey(k)
	}
	if p.tab == TabMCP {
		return p.mcpKey(k)
	}
	switch p.tab {
	case TabHarnesses:
		if p.data.harn == nil || len(p.data.harn.Rows) == 0 {
			return nil
		}
		h := p.data.harn.Rows[min(p.sel[p.tab], len(p.data.harn.Rows)-1)]
		switch k {
		case "D":
			return p.run("harness", "scan")
		case "A":
			return p.configSave("discovery.auto", map[bool]string{true: "off", false: "on"}[p.data.harn.AutoDiscover])
		case "u":
			if h.Update == "" {
				p.notice = h.Name + " has no update command AFK knows"
				return nil
			}
			return p.run("harness", "update", h.Name)
		case "U":
			return p.run("harness", "update", "--all")
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
		switch k {
		case "e":
			return p.run("config", "edit")
		case "enter", "space", "right", "l":
			return p.configChange(1)
		case "left", "h":
			return p.configChange(-1)
		case "x":
			_, _, e, _ := p.configRow()
			switch {
			case e.Remove == "":
			case armed == e.Remove:
				src, ctx, section := p.src, p.ctx, e.Remove
				return func() tea.Msg {
					text, err := src.ConfigRemove(ctx, section)
					return configSavedMsg{text, err}
				}
			default:
				p.cfgRemove = e.Remove
				p.notice = "press x again to remove " + e.Remove + " from config.toml"
			}
			return nil
		}
	case TabRuns:
		if k == "c" && p.anySetAside() {
			src, ctx := p.src, p.ctx
			return func() tea.Msg {
				text, err := src.ClearMarks(ctx)
				return marksClearedMsg{text, err}
			}
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
	id := p.id
	editor := len(args) > 1 && args[1] == "edit" // config, mcp or skills edit: the editor was the point
	return execPaused(argv, editor, func(err error) tea.Msg { return panelExecMsg{panel: id, err: err} })
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
	case TabSkills:
		return p.data.skills != nil
	case TabMCP:
		return p.data.mcp != nil
	}
	return true
}

// rows is how many selectable rows the tab has.
func (p *Panel) rows() int { return p.rowsOf(p.tab) }

func (p *Panel) rowsOf(t Tab) int {
	switch t {
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
	case TabSkills:
		if p.data.skills != nil {
			return len(p.data.skills.Rows)
		}
	case TabMCP:
		if p.data.mcp != nil {
			return len(p.data.mcp.Rows)
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
	out := p.theme.navLines(p.tab, w, p.versionLabel())
	out = append(out, p.subtitle(w), nil)
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
		case TabSkills:
			body, hint = p.skillsLines(w)
		case TabMCP:
			if p.tools != nil {
				body, hint = p.toolsLines(w)
			} else {
				body, hint = p.mcpLines(w)
			}
		case TabRuns:
			body, hint = p.statusLines(w)
		case TabConfig:
			body, hint = p.configLines(w)
		}
	}
	if p.pal != nil {
		body, hint = p.palLines(w), line{sg(t.Key, "↑↓"), sg(t.Dim, " pick  "), sg(t.Key, "↵"), sg(t.Dim, " run  "), sg(t.Key, "esc"), sg(t.Dim, " close  ")}
	}
	if a := p.ask; a != nil && a.tab == p.tab && p.loaded(p.tab) && p.data.err[p.tab] == "" {
		// The input sits above the rows, so it never scrolls out of view.
		in := []line{{sg(t.Key, " "+a.label+" "), sg(t.Plain, a.text), sg(t.Accent, "▏")}}
		for _, l := range wrap(a.hint, max(w-4, 20)) {
			in = append(in, line{sg(t.Dim, "  "+l)})
		}
		body = append(append(in, nil), body...)
		hint = line{sg(t.Key, "↵"), sg(t.Dim, " save  "), sg(t.Key, "esc"), sg(t.Dim, " cancel  ")}
	}
	if f := p.filter[p.tab]; f != "" && p.loaded(p.tab) && p.rows() == 0 && p.data.err[p.tab] == "" {
		body = []line{{sg(t.Dim, " Nothing matches “"+f+"”. "), sg(t.Key, "esc"), sg(t.Dim, " clears the filter.")}}
	}
	// The tab's own keys on the left, the panel's at the right; the
	// tab's on a second row when both don't fit.
	filter := filterable(p.tab) && !(p.tab == TabMCP && p.tools != nil)
	typingValue := p.tab == TabConfig && p.cfgKey != "" || p.ask != nil && p.ask.tab == p.tab || p.pal != nil
	hints := hintPairs(hint)
	var right [][2]string
	if !typingValue {
		if filter {
			hints = append(hints, [2]string{"/", "filter"})
		}
		hints = append(hints, [2]string{"r", "refresh"})
		right = [][2]string{{"ctrl+p", "commands"}, {"esc", p.escLabel()}, {"q", "quit"}}
	}
	footer := p.theme.keyBars(hints, right, w)
	fl := p.filterLine()
	if p.height > 0 {
		// The tab bar and its gap, the notice and the hints keep their
		// rows; the body scrolls to keep the selected row in view.
		room := p.height - len(out) - len(footer)
		if fl != nil {
			room--
		}
		if p.notice != "" {
			room -= 1 + len(wrap(p.notice, max(w-2, 20)))
		}
		body = scrollTo(body, max(room, 1))
	}
	for _, l := range body {
		out = append(out, fitLine(l, w))
	}
	if p.notice != "" {
		// Wrapped, not cut: a refusal's reason is the part that matters.
		out = append(out, nil)
		for _, l := range wrap(p.notice, max(w-2, 20)) {
			out = append(out, line{sg(t.Warn, " "+l)})
		}
	}
	// The hints sit on the last row when the height is known, with the
	// filter just above them.
	end := p.height - len(footer)
	if fl != nil {
		end--
	}
	if p.height > 0 {
		for len(out) < end {
			out = append(out, nil)
		}
	} else {
		out = append(out, nil)
	}
	if fl != nil {
		out = append(out, fitLine(fl, w))
	}
	return append(out, footer...)
}

// versionLabel is what sits at the right of the strip.
func (p *Panel) versionLabel() string {
	if p.version == "" {
		return ""
	}
	return "afk " + p.version
}

// escLabel is what esc does here.
func (p *Panel) escLabel() string {
	if p.filter[p.tab] != "" {
		return "clear filter"
	}
	if p.standalone {
		return "quit"
	}
	return "back"
}

// subtitle is the line under the strip: what this tab is for.
func (p *Panel) subtitle(w int) line {
	t := p.theme
	l := line{sg(t.Bold, " "+tabNames[p.tab]), sg(t.Dim, "  "+tabBlurbs[p.tab])}
	if p.loading[p.tab] {
		l = append(l, sg(t.Accent, "  "+spinFrames[0]), sg(t.Dim, " loading"))
	}
	return fitLine(l, w)
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
	hint := line{sg(t.Key, "↑↓"), sg(t.Dim, " pick  "), sg(t.Key, "D"), sg(t.Dim, " discover now  "), sg(t.Key, "u"), sg(t.Dim, " update  "), sg(t.Key, "U"), sg(t.Dim, " update all  "), sg(t.Key, "l"), sg(t.Dim, " sign in  "), sg(t.Key, "d"), sg(t.Dim, " doctor  ")}
	if len(v.Rows) == 0 {
		return []line{{sg(t.Dim, " No agent CLI found on this machine. Install claude, codex, grok, opencode, agy or pi, then press "), sg(t.Key, "D"), sg(t.Dim, ".")}}, hint
	}
	// The key that flips it is on this line, so the footer stays short.
	auto := line{sg(t.Dim, " auto discovery  ")}
	if v.AutoDiscover {
		auto = append(auto, t.dot("ok"), sg(t.Plain, " on   "), sg(t.Key, "A"), sg(t.Dim, " turn off"))
	} else {
		auto = append(auto, t.dot(""), sg(t.Plain, " off  "), sg(t.Key, "A"), sg(t.Dim, " turn on · AFK keeps the last answer until you press D"))
	}
	head := []line{auto}
	sel := min(p.sel[TabHarnesses], len(v.Rows)-1)
	if w < twoPaneMin {
		list := p.harnessList(w)
		return append(append(append(head, list...), nil), p.harnessDetail(v.Rows[sel], w-2)...), hint
	}
	lw := 50
	head = append(head, nil)
	return append(head, t.twoPane(p.harnessList(lw), lw, p.harnessDetail(v.Rows[sel], w-lw-3), w)...), hint
}

// harnessList is the CLIs, installed ones first, each group headed.
func (p *Panel) harnessList(w int) []line {
	t := p.theme
	v := p.data.harn
	installed := 0
	for _, h := range v.Rows {
		if h.Installed {
			installed++
		}
	}
	var out []line
	for i, h := range v.Rows {
		switch {
		case i == 0 && h.Installed:
			// The column names line up with the rows: logo, space, name.
			out = append(out, append(t.groupHead("Installed", installed).pad(2+1+14, t.Plain), sg(t.Dim, col("version", 10)+"sign-in")))
		case !h.Installed && (i == 0 || v.Rows[i-1].Installed):
			if i > 0 {
				out = append(out, nil)
			}
			out = append(out, t.groupHead("Not installed", len(v.Rows)-installed))
		}
		name := h.Display
		if name == "" {
			name = h.Name
		}
		st := t.Plain
		if i == p.sel[TabHarnesses] {
			st = t.Bold
		}
		row := line{harnessLogo(t, h.Name), sg(st, " "+col(name, 14))}
		if !h.Installed {
			row = line{harnessLogo(t, h.Name), sg(t.Dim, " "+name)}
		} else {
			ver := h.Version
			if ver == "" {
				ver = unknownText
			}
			state, text := signInState(h)
			textSt := t.Plain
			if state != "ok" {
				textSt = t.Dim
			}
			if state == "bad" {
				textSt = t.Warn
			}
			row = append(row, sg(t.Plain, col(ver, 10)), t.dot(state), sg(textSt, " "+text))
		}
		out = append(out, p.selRow(row, i, w))
	}
	return out
}

// signInState is a CLI's sign-in as a dot state and the words beside it.
func signInState(h HarnessRow) (string, string) {
	s := h.SignIn
	switch {
	case s == "" || s == "unknown":
		return "", "not reported"
	case strings.Contains(s, "signed out") || strings.Contains(s, "expired"):
		return "bad", s
	case s == "login on disk":
		// A login file exists, but the CLI hasn't said it still works.
		return "partly", s
	}
	return "ok", s
}

// harnessDetail is the selected CLI in full.
func (p *Panel) harnessDetail(h HarnessRow, w int) []line {
	t := p.theme
	name := h.Display
	if name == "" {
		name = h.Name
	}
	head := line{harnessLogo(t, h.Name), sg(t.Bold, " "+name)}
	if name != h.Name {
		head = append(head, sg(t.Dim, "   "+h.Name))
	}
	out := []line{
		head,
		{sg(t.Border, strings.Repeat("─", max(min(w, 60), 10)))},
	}
	if !h.Installed {
		out = append(out, line{sg(t.Dim, "Not installed on this machine.")})
		if h.Note != "" {
			for _, l := range wrap(h.Note, max(w, 20)) {
				out = append(out, line{sg(t.Dim, l)})
			}
		}
		return out
	}
	ver := h.Version
	if ver == "" {
		ver = unknownText
	}
	out = append(out, t.field("Version", sg(t.Plain, ver)))
	inst := line{}
	if h.Method != "" {
		inst = append(inst, sg(t.Plain, h.Method))
	}
	if h.Path != "" {
		if len(inst) > 0 {
			inst = append(inst, sg(t.Dim, " · "))
		}
		inst = append(inst, sg(t.Dim, h.Path))
	}
	if len(inst) > 0 {
		out = append(out, t.field("Installed", inst...))
	}
	state, text := signInState(h)
	out = append(out, t.field("Sign-in", t.dot(state), sg(t.Plain, " "+text)))
	if h.Routes != "" {
		out = append(out, t.field("Routes", sg(t.Plain, h.Routes)))
	}
	if h.Note != "" {
		for _, l := range wrap(h.Note, max(w-10, 20)) {
			out = append(out, line{sg(t.Dim, strings.Repeat(" ", 10)+l)})
		}
	}
	out = append(out, nil)
	usage := strings.TrimPrefix(h.Usage, "usage ")
	if usage == "" || usage == "unknown" {
		usage = "not reported by " + h.Name
	}
	out = append(out, t.wrapField("Usage", usage, w)...)
	if len(h.Models) > 0 {
		out = append(out, t.wrapField("Models", strings.Join(h.Models, ", "), w)...)
	}
	if h.Update != "" {
		out = append(out, t.wrapField("Updates", h.Update, w)...)
	}
	return out
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

// marksClearedMsg is what clearing the failed-run marks said.
type marksClearedMsg struct {
	text string
	err  error
}

// anySetAside reports a plan a failed run set aside.
func (p *Panel) anySetAside() bool {
	if p.data.status == nil || p.src == nil {
		return false
	}
	for _, pl := range p.data.status.Plans {
		if pl.SetAside {
			return true
		}
	}
	return false
}

func (p *Panel) statusLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.status
	out := []line{}
	if !v.Updated.IsZero() {
		out = append(out, line{sg(t.Dim, " updated "+v.Updated.Format("15:04")+" · "), sg(t.Key, "r"), sg(t.Dim, " refresh")}, nil)
	}
	// The plan column grows to fit the longest label, so a reported tier
	// ("ChatGPT plan · enterprise") is never cut.
	pw := 19
	for _, pl := range v.Plans {
		pw = max(pw, line{sg(t.Plain, pl.Plan)}.width()+2)
	}
	out = append(out, line{sg(t.Bold, " Plans"), sg(t.Dim, strings.Repeat(" ", pw-2)+col("5h left", 19)+col("week left", 19)+"sign-in")})
	// A window with no reported figure says "unknown": no empty meter
	// that could be read as a spent plan.
	cell := func(pct *float64, none bool) line {
		l := line{sg(t.Dim, "unknown")}
		if none && pct == nil {
			l = line{sg(t.Plain, "no limit")}
		}
		if pct != nil {
			l = append(t.meter(pct, 1), sg(t.Plain, " "+pctText(pct)))
		}
		return append(l, sg(t.Plain, strings.Repeat(" ", max(1, 19-l.width()))))
	}
	for _, pl := range v.Plans {
		row := line{sg(t.Plain, " "), harnessLogo(t, pl.Harness), sg(t.Plain, " "+col(pl.Plan, pw))}
		row = append(row, cell(pl.FiveHour, pl.NoFiveHour)...)
		row = append(row, cell(pl.Week, pl.NoWeek)...)
		signSt := t.Warn
		switch pl.SignIn {
		case "signed in":
			signSt = t.OK
		case "login on disk", "unknown":
			// Not confirmed by the CLI itself: neither good nor bad.
			signSt = t.Dim
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
	if p.anySetAside() {
		return out, line{sg(t.Key, "c"), sg(t.Dim, " clear failed-run marks  ")}
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
	out := []line{head, nil}
	list := p.configList(w)
	focus := p.cfgKey != "" || p.cfgAskKey != ""
	switch {
	case focus:
		out = append(out, list...)
	case w >= 96:
		// The list on the left, what the selected setting does on the right.
		lw := 46
		list = p.configList(lw)
		detail := p.configDetail(w - lw - 4)
		for i := 0; i < max(len(list), len(detail)); i++ {
			var l line
			if i < len(list) {
				l = list[i]
			}
			if i < len(detail) {
				l = append(l.pad(lw, t.Plain), sg(t.Border, " │  "))
				l = append(l, detail[i]...)
			}
			out = append(out, l)
		}
	default:
		out = append(out, list...)
		out = append(out, nil)
		for _, l := range p.configDetail(w - 4) {
			out = append(out, append(line{sg(t.Plain, "  ")}, l...))
		}
	}
	for _, wn := range v.Warnings {
		out = append(out, fitLine(line{sg(t.Warn, " ! "+wn)}, w))
	}
	if p.cfgAskKey != "" {
		out = append(out, nil)
		for _, l := range wrap(p.cfgAsk, max(w-4, 20)) {
			out = append(out, line{sg(t.Dim, "  "+l)})
		}
		return out, line{sg(t.Key, "↵"), sg(t.Dim, " turn on  "), sg(t.Key, "esc"), sg(t.Dim, " leave off  ")}
	}
	if p.cfgKey != "" {
		// What to type goes under the table, wrapped: it can be long.
		if p.cfgHint != "" {
			out = append(out, nil)
			for _, l := range wrap(p.cfgHint, max(w-4, 20)) {
				out = append(out, line{sg(t.Dim, "  "+l)})
			}
		}
		return out, line{sg(t.Key, "↵"), sg(t.Dim, " save  "), sg(t.Key, "esc"), sg(t.Dim, " cancel  ")}
	}
	hint := line{sg(t.Key, "↵"), sg(t.Dim, " change  ")}
	if _, _, e, _ := p.configRow(); e.Remove != "" {
		hint = append(hint, sg(t.Key, "x"), sg(t.Dim, " remove "+e.Remove+"  "))
	}
	hint = append(hint, sg(t.Key, "e"), sg(t.Dim, " edit config.toml  "))
	return out, hint
}

// panelAsk is a line being typed for an action on a tab (a new server, a
// new skill). done gets the text on enter.
type panelAsk struct {
	tab               Tab
	label, text, hint string
	done              func(text string) tea.Cmd
}

// askKey takes a key while a panelAsk is open.
func (p *Panel) askKey(k string) tea.Cmd {
	a := p.ask
	switch k {
	case "enter":
		p.ask = nil
		if text := strings.TrimSpace(a.text); text != "" {
			return a.done(text)
		}
	case "esc":
		p.ask = nil
	case "backspace":
		if a.text != "" {
			_, n := utf8.DecodeLastRuneInString(a.text)
			a.text = a.text[:len(a.text)-n]
		}
	case "space":
		a.text += " "
	case "ctrl+u":
		a.text = ""
	default:
		if utf8.RuneCountInString(k) == 1 {
			a.text += k
		}
	}
	return nil
}

// configSavedMsg is what saving a setting said.
type configSavedMsg struct {
	text string
	err  error
}

// configRow is the selected row's key, value and how it is edited.
func (p *Panel) configRow() (key, value string, e ConfigEdit, ok bool) {
	v := p.data.config
	i := p.sel[TabConfig]
	if v == nil || i < 0 || i >= len(v.Rows) {
		return "", "", ConfigEdit{}, false
	}
	e, ok = v.Edit[v.Rows[i][0]]
	return v.Rows[i][0], v.Rows[i][1], e, ok
}

// configChange changes the selected setting: the next (or previous)
// choice is saved at once; a typed value opens the input.
func (p *Panel) configChange(step int) tea.Cmd {
	key, value, e, ok := p.configRow()
	if key == "" {
		return nil
	}
	if !ok {
		p.notice = key + " can't be changed here yet; e opens config.toml"
		return nil
	}
	if len(e.Choices) == 0 {
		p.cfgKey, p.cfgText, p.cfgHint = key, e.Value, e.Hint
		return nil
	}
	at := 0
	for i, c := range e.Choices {
		if c == value {
			at = i
		}
	}
	n := len(e.Choices)
	next := e.Choices[((at+step)%n+n)%n]
	if e.Confirm != "" && next == "on" {
		p.cfgAskKey, p.cfgAsk = key, e.Confirm
		return nil
	}
	return p.configSave(key, next)
}

func (p *Panel) configSave(key, value string) tea.Cmd {
	if p.src == nil {
		return nil
	}
	src, ctx := p.src, p.ctx
	return func() tea.Msg {
		text, err := src.ConfigSet(ctx, key, value)
		return configSavedMsg{text, err}
	}
}

// configTyping takes a key while a setting's value is being typed.
func (p *Panel) configTyping(k string) tea.Cmd {
	switch k {
	case "enter":
		key, text := p.cfgKey, strings.TrimSpace(p.cfgText)
		p.cfgKey, p.cfgText, p.cfgHint = "", "", ""
		return p.configSave(key, text)
	case "esc":
		p.cfgKey, p.cfgText, p.cfgHint = "", "", ""
	case "backspace":
		if p.cfgText != "" {
			_, n := utf8.DecodeLastRuneInString(p.cfgText)
			p.cfgText = p.cfgText[:len(p.cfgText)-n]
		}
	case "space":
		p.cfgText += " "
	case "ctrl+u":
		p.cfgText = ""
	default:
		if utf8.RuneCountInString(k) == 1 {
			p.cfgText += k
		}
	}
	return nil
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
