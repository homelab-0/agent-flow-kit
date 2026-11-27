package tui

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

type fakePanel struct{ ran [][]string }

func f(v float64) *float64 { return &v }

func (fakePanel) Harnesses(context.Context) (*HarnessesView, error) {
	return &HarnessesView{Rows: []HarnessRow{
		{Name: "claude", Version: "2.1.332", Installed: true, SignIn: "signed in", Routes: "plan+gw", Update: "claude update",
			Path: "/usr/local/bin/claude", Method: "native installer", Models: []string{"claude-fable-5-2", "sonnet", "+2 via gateway"}, Usage: "5h 71% left · week 64% left"},
		{Name: "codex", Version: "0.172.0", Installed: true, SignIn: "signed in", Routes: "plan", Update: "npm i -g @openai/codex"},
		{Name: "grok", Version: "0.9.4", Installed: true, SignIn: "signed in", Routes: "plan"},
		{Name: "opencode", Version: "1.4.0", Installed: true, SignIn: "signed out", Routes: "gw"},
		{Name: "pi", Installed: false},
	}}, nil
}

func (fakePanel) Benchmarks(_ context.Context, task string) (*BenchView, error) {
	gw := engine.Route{LaunchClass: "claude-gateway"}
	ol := engine.Route{LaunchClass: "claude-local", Engine: "ollama"}
	return &BenchView{Task: task, Source: "SWE-bench Verified · catalog 2026-11-27", Rows: []BenchRow{
		{Model: "claude-fable-5-2", Via: []engine.Route{{Harness: "claude"}}, Score: f(78.1), Basis: "measured", Solved: 14, Partly: 2},
		{Model: "gpt-6.1-sol", Via: []engine.Route{{Harness: "codex"}, {Harness: "opencode"}}, Score: f(76.4), Basis: "measured", Solved: 9, Partly: 1},
		{Model: "grok-4.7", Via: []engine.Route{{Harness: "grok"}}, Score: f(69), Basis: "estimate", Solved: 2, Wrong: 1},
		{Model: "qwen36-27b", Via: []engine.Route{gw}, Score: f(58.2), Basis: "measured"},
		{Model: "qwen36-14b", Via: []engine.Route{ol}, Score: f(51), Basis: "estimate"},
	}, Routes: []engine.Route{
		{Harness: "claude", EffectiveScore: f(78.1), PoolHeadroomPct: f(78)},
		{Harness: "codex", EffectiveScore: f(71.8), PoolHeadroomPct: f(52)},
		{LaunchClass: "claude-local", Engine: "ollama", EffectiveScore: f(51)},
	}}, nil
}

func (fakePanel) Status(context.Context) (*StatusView, error) {
	now := time.Date(2026, 11, 27, 3, 31, 0, 0, time.UTC)
	return &StatusView{Updated: now,
		Plans: []PlanRow{
			{Harness: "claude", Plan: "Claude plan", FiveHour: f(71), Week: f(64), SignIn: "ok"},
			{Harness: "codex", Plan: "ChatGPT plan", FiveHour: f(52), Week: f(80), SignIn: "ok"},
			{Harness: "grok", Plan: "SuperGrok", FiveHour: f(91), SignIn: "ok"},
		},
		Gateway: &GatewayRow{Name: "agentgateway", Kind: "agentgateway", State: "up", Detail: "gw.lan · 3 models", Engine: "vllm", EngineHost: "factory"},
		Engines: []EngineRow{{Engine: "ollama", State: "idle", Where: "this PC · RTX 5090", Models: []string{"qwen36-14b"}}},
		Runs: []RunRow{
			{ID: "r-7f3c", Where: "here", CLI: "claude", Model: "claude-fable-5-2", Outcome: "solved", Started: now.Add(-30 * time.Minute), Duration: 23 * time.Minute},
			{ID: "r-7f1a", Where: "here", CLI: "codex", Model: "gpt-6.1-sol", Exit: 1, Started: now.Add(-3 * time.Hour), Duration: 8 * time.Minute},
		}}, nil
}

func (fakePanel) Config(context.Context) (*ConfigView, error) {
	return &ConfigView{Path: "~/.config/afk/config.toml", Exists: true, Rows: [][2]string{{"route.prefer", "balanced"}, {"gateway", "agentgateway · gw.lan"}}}, nil
}

func (fakePanel) Skills(context.Context) (*SkillsView, error) {
	now := time.Date(2026, 11, 27, 3, 31, 0, 0, time.UTC)
	return &SkillsView{Source: "~/.config/afk/skills", Cols: []string{"claude", "codex", "grok"}, Unsupported: []string{"agy"}, Pending: 1,
		Rows: []SkillRow{
			{Name: "humanizer", Central: true, Cells: map[string]string{"claude": "synced", "codex": "synced", "grok": "synced"}},
			{Name: "gh-pr-triage", Central: true, Cells: map[string]string{"claude": "synced", "codex": "synced", "grok": "drifted"}},
			{Name: "outline-notes", Central: true, Cells: map[string]string{"claude": "synced", "codex": "off", "grok": "pending"}},
			{Name: "prox-ops-deploy", Central: true, Project: true, Cells: map[string]string{"claude": "ask", "codex": "native", "grok": "unsupported"}},
		},
		Project: "~/repos/prox-ops/.agents/skills", Undecided: 1,
		Drift: []SkillDrift{{Skill: "gh-pr-triage", Harness: "grok", Dir: "~/.grok/skills", Modified: now.Add(-2 * time.Hour), Lines: 4}}}, nil
}

func (p *fakePanel) SkillsDo(_ context.Context, op string, args ...string) (string, error) {
	p.ran = append(p.ran, append([]string{"do", op}, args...))
	return "did " + op, nil
}

func (fakePanel) MCP(context.Context) (*MCPView, error) {
	return &MCPView{Source: "~/.config/afk/mcp.toml", Cols: []string{"claude", "codex", "grok"}, Unsupported: []string{"pi"}, Pending: 1,
		Rows: []MCPRow{
			{Name: "openconnector", Via: "homelab", Listed: true, Tools: 312, Status: "up", Tested: "2h ago", Cells: map[string]string{"claude": "synced", "codex": "synced", "grok": "synced"}},
			{Name: "github", Via: "homelab", Listed: true, Tools: 48, Status: "up", Tested: "2h ago", Cells: map[string]string{"claude": "synced", "codex": "drifted", "grok": "unsupported"}, Notes: map[string]string{"grok": "grok can't pass a token by name"}},
			{Name: "playwright", Via: "stdio", Listed: true, Tools: -1, Status: "untested", Cells: map[string]string{"claude": "synced", "codex": "pending", "grok": "off"}},
			{Name: "repo-db", Via: "stdio", Listed: true, Tools: -1, Status: "untested", Project: true, Cells: map[string]string{"claude": "native", "codex": "ask", "grok": "unsupported"}},
		},
		Project: "~/repos/prox-ops/.mcp.json", Undecided: 1,
		Drift: []MCPDrift{{Server: "github", Harness: "codex", File: "~/.codex/config.toml"}}}, nil
}

func (p *fakePanel) MCPDo(_ context.Context, op string, args ...string) (string, error) {
	p.ran = append(p.ran, append([]string{"mcp", op}, args...))
	return "did " + op, nil
}

func (p *fakePanel) MCPTools(_ context.Context, server string) ([]MCPTool, error) {
	p.ran = append(p.ran, []string{"mcp", "tools", server})
	if server == "playwright" {
		return nil, errors.New("playwright: exec: npx not found")
	}
	return []MCPTool{{"create_issue", "Create an issue\nin a repository."}, {"list_pulls", "List pull requests."}, {"search_code", ""}}, nil
}

func (p *fakePanel) Command(args ...string) []string { return append([]string{"afk"}, args...) }

// panelAt opens a panel on a tab and loads it.
func panelAt(t *testing.T, tab Tab) *Panel {
	t.Helper()
	now := func() time.Time { return time.Date(2026, 11, 27, 3, 31, 0, 0, time.UTC) }
	p := NewPanel(context.Background(), &fakePanel{}, NewTheme(true), tab, "0.2.0", now)
	p.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	if cmd := p.Init(); cmd != nil {
		p.Update(cmd())
	}
	return p
}

func panelText(p *Panel) string {
	var out []string
	for _, l := range p.Lines() {
		out = append(out, strings.TrimRight(l.plain(), " "))
	}
	return strings.Join(out, "\n")
}

func TestPanelTabs(t *testing.T) {
	for tab, want := range map[Tab][]string{
		TabHarnesses: {"Route   Harnesses   Benchmarks   Skills   MCP   Runs   Config", "afk 0.2.0", "CL claude    2.1.332  signed in      plan+gw  u",
			"OC opencode  1.4.0    signed out", "PI pi        —        not installed", "models  claude-fable-5-2, sonnet, +2 via gateway", "usage   5h 71% left · week 64% left", "u update"},
		TabBench:  {"task   coding  quick", "source SWE-bench Verified", "claude-fable-5-2   CL", "78.1  measured  14✓ 2~", "CX OC", "qwen36-14b         OL", "Effective today", "CX 71.8 (52%)", "OL 51.0", "←→ task"},
		TabRuns:   {"updated 03:31", "CL Claude plan", "71%", "GK SuperGrok", "[??????????] n/e", "agentgateway      up", "└ VL vLLM", "OL ollama", "this PC · RTX 5090 · 1 model", "r-7f3c", "✓ solved", "! exit 1", "23m · 30m ago"},
		TabConfig: {"file ~/.config/afk/config.toml", "route.prefer                balanced", "e edit config.toml"},
		TabSkills: {"4 skills · source ~/.config/afk/skills · 1 drifted · 1 to sync · 1 to choose", "skill", "CL  CX  GK  AG", "gh-pr-triage", "↻", "╭─ gh-pr-triage changed in grok",
			"Edited in ~/.grok/skills 2 hours ago. 4 lines differ from central.", "k keep grok's and update central", "space enable"},
		TabMCP: {"4 servers · ~/.config/afk/mcp.toml · 360 tools · 1 drifted · 1 to sync", "server", "CL  CX  GK  PI  status", "openconnector",
			"312", "up · 2h ago", "untested", "╭─ github changed in codex", "k keep codex's as its own", "t test"},
	} {
		s := panelText(panelAt(t, tab))
		for _, w := range want {
			if !strings.Contains(s, w) {
				t.Errorf("tab %s: missing %q in\n%s", tabNames[tab], w, s)
			}
		}
		if lines := strings.Count(s, "\n") + 1; lines != 24 {
			t.Errorf("tab %s is %d lines, want the full 24", tabNames[tab], lines)
		}
		if !strings.Contains(strings.Split(s, "\n")[23], "1-7 tabs") {
			t.Errorf("tab %s: the hints aren't on the last row", tabNames[tab])
		}
	}
}

func TestPanelKeys(t *testing.T) {
	p := panelAt(t, TabHarnesses)
	p.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	if p.sel[TabHarnesses] != 1 || !strings.Contains(panelText(p), "▌") {
		t.Error("down didn't move the selection")
	}
	// 3 switches to Benchmarks and loads it.
	cmd := p.Update(tea.KeyPressMsg{Code: '3', Text: "3"})
	if p.tab != TabBench || cmd == nil {
		t.Fatalf("3 went to %d", p.tab)
	}
	p.Update(cmd())
	cmd = p.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	p.Update(cmd())
	if !strings.Contains(panelText(p), "quick") || p.data.bench.Task != "quick" {
		t.Errorf("right didn't step the task: %q", p.data.bench.Task)
	}
	// 1 is Route: back to the composer, or quit when on its own.
	p.Update(tea.KeyPressMsg{Code: '1', Text: "1"})
	if !p.back {
		t.Error("1 didn't go back to Route")
	}
	s := panelAt(t, TabRuns).Standalone()
	s.Update(tea.KeyPressMsg{Code: '1', Text: "1"})
	if !s.quit {
		t.Error("1 didn't quit afk status")
	}
}

func TestSkillsTabKeys(t *testing.T) {
	src := &fakePanel{}
	now := func() time.Time { return time.Date(2026, 11, 27, 3, 31, 0, 0, time.UTC) }
	p := NewPanel(context.Background(), src, NewTheme(true), TabSkills, "", now)
	p.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	p.Update(p.Init()())
	do := func(k tea.KeyPressMsg) {
		if cmd := p.Update(k); cmd != nil {
			if msg := cmd(); msg != nil {
				if c2 := p.Update(msg); c2 != nil {
					p.Update(c2())
				}
			}
		}
	}
	// Row 0, column 0 (claude): synced, so space turns it off.
	do(tea.KeyPressMsg{Code: tea.KeySpace, Text: " "})
	// Down to outline-notes, right to codex (off): space turns it on.
	do(tea.KeyPressMsg{Code: tea.KeyDown})
	do(tea.KeyPressMsg{Code: tea.KeyDown})
	do(tea.KeyPressMsg{Code: tea.KeyRight})
	do(tea.KeyPressMsg{Code: tea.KeySpace, Text: " "})
	// Up to gh-pr-triage: k keeps grok's copy, c restores central.
	do(tea.KeyPressMsg{Code: tea.KeyUp})
	do(tea.KeyPressMsg{Code: 'k', Text: "k"})
	do(tea.KeyPressMsg{Code: 'c', Text: "c"})
	do(tea.KeyPressMsg{Code: 's', Text: "s"})
	want := "do disable humanizer claude|do enable outline-notes codex|do keep gh-pr-triage grok|do restore gh-pr-triage grok|do sync"
	var got []string
	for _, r := range src.ran {
		got = append(got, strings.Join(r, " "))
	}
	if strings.Join(got, "|") != want {
		t.Errorf("actions\n got %s\nwant %s", strings.Join(got, "|"), want)
	}
	if !strings.Contains(panelText(p), "did sync") {
		t.Errorf("the action's notice isn't shown:\n%s", panelText(p))
	}
	// The box stays on the drift when another skill is picked.
	do(tea.KeyPressMsg{Code: tea.KeyUp})
	if !strings.Contains(panelText(p), "╭─ gh-pr-triage changed in grok") {
		t.Error("the drift box went away")
	}
}

func TestTabFor(t *testing.T) {
	for in, want := range map[string]Tab{"/harnesses": TabHarnesses, "bench": TabBench, "/runs": TabRuns, "status": TabRuns, "/config": TabConfig, "/mcp": TabMCP, "/skills": TabSkills} {
		if got, ok := TabFor(in); !ok || got != want {
			t.Errorf("TabFor(%q) = %d, %v", in, got, ok)
		}
	}
	if _, ok := TabFor("/nope"); ok {
		t.Error("unknown tab accepted")
	}
}

// From the composer, /harnesses and 2-7 open the tabs; esc or 1 goes back.
func TestComposerOpensTabs(t *testing.T) {
	m, _ := composeModel(t, 80, false)
	m.opt.Panel = &fakePanel{}
	typeText(m, "/bench")
	_, cmd := m.Update(key("enter"))
	if m.panel == nil || m.panel.tab != TabBench {
		t.Fatal("/bench didn't open the Benchmarks tab")
	}
	m.Update(cmd())
	if !m.View().AltScreen || !strings.Contains(m.View().Content, "claude-fable-5-2") {
		t.Error("the tab isn't drawn full screen")
	}
	m.Update(key("esc"))
	if m.panel != nil || m.st != sCompose {
		t.Fatal("esc didn't go back to the composer")
	}
	m.Update(key("6"))
	if m.panel == nil || m.panel.tab != TabRuns {
		t.Fatal("6 didn't open Runs")
	}
	m.Update(key("1"))
	if m.panel != nil {
		t.Fatal("1 didn't go back to Route")
	}
	// /harness alone still unpins the CLI, and digits type in a task.
	typeText(m, "/harness")
	m.Update(key("enter"))
	if m.panel != nil {
		t.Error("/harness opened a tab")
	}
	typeText(m, "fix 2 bugs")
	if m.panel != nil || m.cin.Value() != "fix 2 bugs" {
		t.Errorf("a digit in a task opened a tab: %q", m.cin.Value())
	}
}

func TestPanelIgnoresStaleLoads(t *testing.T) {
	p := panelAt(t, TabConfig)
	old := p.load(TabConfig)
	newer := p.load(TabConfig)
	p.Update(newer())
	p.data.config.Path = "newer"
	msg := old().(panelMsg)
	msg.err = context.Canceled
	p.Update(msg)
	if p.data.err[TabConfig] != "" || p.data.config.Path != "newer" {
		t.Error("an older load replaced a newer one")
	}
	// A load from a panel that was closed never reaches the next one.
	q := panelAt(t, TabConfig)
	msg.panel, msg.gen = p.id, q.gens[TabConfig]
	q.Update(msg)
	if q.data.err[TabConfig] != "" {
		t.Error("another opening's load reached this panel")
	}
}

func TestPanelScrollsAndNarrowTabs(t *testing.T) {
	p := panelAt(t, TabRuns)
	p.Update(tea.WindowSizeMsg{Width: 80, Height: 12})
	for range 10 {
		p.Update(key("down"))
	}
	s := panelText(p)
	if n := strings.Count(s, "\n") + 1; n != 12 || !strings.Contains(s, "▌") || !strings.Contains(s, "1-7 tabs") {
		t.Errorf("a short terminal should scroll to the selected run (%d lines):\n%s", n, s)
	}
	p.Update(tea.WindowSizeMsg{Width: 50, Height: 24})
	p.Update(key("7"))
	if bar := strings.Split(panelText(p), "\n")[0]; !strings.Contains(bar, "7 Config") || lenCells(bar) > 50 {
		t.Errorf("narrow tab bar %q", bar)
	}
}

func TestBenchHidesAnotherTasksScores(t *testing.T) {
	p := panelAt(t, TabBench)
	p.Update(key("right")) // quick, still loading
	if s := panelText(p); !strings.Contains(s, "loading") {
		t.Errorf("coding's scores showed under quick:\n%s", s)
	}
}

func TestMCPTabKeys(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabMCP, "", nil)
	p.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	p.Update(p.Init()())
	do := func(k tea.KeyPressMsg) {
		if cmd := p.Update(k); cmd != nil {
			if msg := cmd(); msg != nil {
				if c2 := p.Update(msg); c2 != nil {
					p.Update(c2())
				}
			}
		}
	}
	do(tea.KeyPressMsg{Code: 't', Text: "t"})
	do(tea.KeyPressMsg{Code: tea.KeyDown})
	do(tea.KeyPressMsg{Code: tea.KeyRight})
	do(tea.KeyPressMsg{Code: tea.KeyRight})
	do(tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}) // grok can't take github: a notice
	if !strings.Contains(panelText(p), "can't pass a token") {
		t.Errorf("no reason shown:\n%s", panelText(p))
	}
	do(tea.KeyPressMsg{Code: 'k', Text: "k"})
	do(tea.KeyPressMsg{Code: 'c', Text: "c"})
	do(tea.KeyPressMsg{Code: tea.KeyDown})
	do(tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}) // playwright in grok: off, so enable
	do(tea.KeyPressMsg{Code: 's', Text: "s"})
	want := "mcp test openconnector|mcp keep github codex|mcp restore github codex|mcp enable playwright grok|mcp sync"
	var got []string
	for _, r := range src.ran {
		got = append(got, strings.Join(r, " "))
	}
	if strings.Join(got, "|") != want {
		t.Errorf("actions\n got %s\nwant %s", strings.Join(got, "|"), want)
	}
}

func TestSkillsProjectScope(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabSkills, "", nil)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	p.Update(p.Init()())
	s := panelText(p)
	for _, w := range []string{"1 to choose", "prox-ops-deploy", "project", "project: ~/repos/prox-ops/.agents/skills"} {
		if !strings.Contains(s, w) {
			t.Errorf("missing %q in\n%s", w, s)
		}
	}
	for range 3 {
		p.Update(key("down"))
	}
	// space on an undecided project skill asks where it goes; esc
	// leaves the question for later without leaving the panel.
	p.Update(key(" "))
	if p.askScope != "prox-ops-deploy" {
		t.Fatalf("space didn't ask: %q", p.askScope)
	}
	p.Update(key("esc"))
	if p.askScope != "" || p.back {
		t.Fatalf("esc: ask=%q back=%v", p.askScope, p.back)
	}
	p.Update(key(" "))
	if !strings.Contains(panelText(p), "Install prox-ops-deploy") || !strings.Contains(panelText(p), "g every project") {
		t.Fatalf("no scope question:\n%s", panelText(p))
	}
	if cmd := p.Update(key("g")); cmd != nil {
		p.Update(cmd())
	}
	want := []string{"do", "project:scope", "prox-ops-deploy", "global"}
	if len(src.ran) == 0 || strings.Join(src.ran[len(src.ran)-1], " ") != strings.Join(want, " ") {
		t.Errorf("ran %v, want %v", src.ran, want)
	}
}

func TestPanelFilter(t *testing.T) {
	p := panelAt(t, TabHarnesses)
	keys := func(ks ...string) {
		for _, k := range ks {
			p.Update(key(k))
		}
	}
	keys("down", "down") // grok selected
	keys("/", "o", "d")
	s := panelText(p)
	if !strings.Contains(s, "codex") || !strings.Contains(s, "opencode") || strings.Contains(s, "grok") || strings.Contains(s, "claude ") {
		t.Fatalf("filter od should keep codex and opencode:\n%s", s)
	}
	if !strings.Contains(s, "/ od") {
		t.Errorf("the filter being typed is not shown:\n%s", s)
	}
	if p.sel[TabHarnesses] != 0 {
		t.Errorf("selection %d, want the first match", p.sel[TabHarnesses])
	}
	// q and digits are typed into the filter, not acted on.
	keys("q")
	if p.quit || p.filter[TabHarnesses] != "odq" {
		t.Fatalf("q while typing: quit=%v filter=%q", p.quit, p.filter[TabHarnesses])
	}
	keys("enter")
	if !strings.Contains(panelText(p), "Nothing matches “odq”") {
		t.Errorf("no-match message missing:\n%s", panelText(p))
	}
	// After enter the keys work again; the first esc clears the filter
	// instead of leaving.
	keys("esc")
	if p.back || p.filter[TabHarnesses] != "" || !strings.Contains(panelText(p), "grok") {
		t.Fatalf("esc should clear the filter: back=%v filter=%q", p.back, p.filter[TabHarnesses])
	}
	// A reload keeps the filter applied.
	keys("/", "c", "l", "enter")
	if cmd := p.load(TabHarnesses); cmd != nil {
		p.Update(cmd())
	}
	if s := panelText(p); strings.Contains(s, "codex") || !strings.Contains(s, "claude") {
		t.Errorf("filter lost on reload:\n%s", s)
	}
	keys("esc", "esc")
	if !p.back {
		t.Error("the second esc should leave the panel")
	}
}

func TestMCPToolsList(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabMCP, "", nil)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	p.Update(p.Init()())
	run := func(k string) {
		if cmd := p.Update(key(k)); cmd != nil {
			if c2 := p.Update(cmd()); c2 != nil {
				p.Update(c2())
			}
		}
	}
	if !strings.Contains(panelText(p), "↵ tools") {
		t.Error("the hints should offer ↵ tools")
	}
	run("down") // github
	run("enter")
	s := panelText(p)
	if !strings.Contains(s, "github · 3 tools") || !strings.Contains(s, "create_issue") || !strings.Contains(s, "Create an issue in a repository.") {
		t.Fatalf("tools list missing:\n%s", s)
	}
	if !strings.Contains(s, "▌ create_issue") {
		t.Errorf("the first tool should be selected:\n%s", s)
	}
	run("down")
	if !strings.Contains(panelText(p), "▌ list_pulls") {
		t.Errorf("down should move to the next tool:\n%s", panelText(p))
	}
	run("esc")
	if p.back || p.tools != nil || !strings.Contains(panelText(p), "openconnector") {
		t.Fatalf("esc should go back to the servers: back=%v", p.back)
	}
	// A server that can't be reached says why and keeps the table.
	run("down")
	run("enter")
	if p.tools != nil || !strings.Contains(panelText(p), "npx not found") {
		t.Errorf("a failed listing should show its error:\n%s", panelText(p))
	}
}

func TestMCPProjectScope(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabMCP, "", nil)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 34})
	p.Update(p.Init()())
	s := panelText(p)
	for _, w := range []string{"1 to choose", "repo-db", "project", "project: ~/repos/prox-ops/.mcp.json"} {
		if !strings.Contains(s, w) {
			t.Errorf("missing %q in\n%s", w, s)
		}
	}
	for range 3 {
		p.Update(key("down"))
	}
	p.Update(key("right")) // codex, which gets a copy
	p.Update(key(" "))
	if p.askScope != "repo-db" {
		t.Fatalf("space didn't ask: %q", p.askScope)
	}
	if !strings.Contains(panelText(p), "Add repo-db") || !strings.Contains(panelText(p), "added to mcp.toml") {
		t.Fatalf("no scope question:\n%s", panelText(p))
	}
	p.Update(key("esc"))
	if p.askScope != "" || p.back {
		t.Fatalf("esc: ask=%q back=%v", p.askScope, p.back)
	}
	p.Update(key(" "))
	if cmd := p.Update(key("p")); cmd != nil {
		p.Update(cmd())
	}
	want := []string{"mcp", "project:scope", "repo-db", "project"}
	if len(src.ran) == 0 || strings.Join(src.ran[len(src.ran)-1], " ") != strings.Join(want, " ") {
		t.Errorf("ran %v, want %v", src.ran, want)
	}
	// The CLI that reads .mcp.json itself says so.
	p.mcpCol = 0
	p.Update(key(" "))
	if !strings.Contains(p.notice, "reads .mcp.json itself") {
		t.Errorf("notice %q", p.notice)
	}
}

func TestMCPToolsEdges(t *testing.T) {
	p := NewPanel(context.Background(), &fakePanel{}, NewTheme(true), TabMCP, "", nil)
	p.Update(tea.WindowSizeMsg{Width: 60, Height: 14})
	p.Update(p.Init()())
	// q quit stays in sight on a narrow screen.
	if s := panelText(p); !strings.Contains(s, "q quit") {
		t.Errorf("q quit cut off at 60 columns:\n%s", s)
	}
	// Only the latest listing opens.
	old := p.mcpListTools("github")
	newer := p.mcpListTools("openconnector")
	p.Update(newer())
	p.Update(old())
	if p.tools == nil || p.tools.server != "openconnector" {
		t.Fatalf("a superseded listing replaced the newer one: %+v", p.tools)
	}
	// A long list scrolls to keep the selected tool in view.
	var many []MCPTool
	for i := range 40 {
		many = append(many, MCPTool{Name: fmt.Sprintf("tool_%02d", i)})
	}
	p.tools = &toolsView{server: "big", tools: many}
	p.Update(key("end"))
	if s := panelText(p); !strings.Contains(s, "▌ tool_39") {
		t.Errorf("the last tool is not in view:\n%s", s)
	}
	// The tab keys still change tabs.
	p.Update(key("2"))
	if p.tab != TabHarnesses || p.tools != nil {
		t.Errorf("2 should leave the tools view for the Harnesses tab: tab=%v", p.tab)
	}
}
