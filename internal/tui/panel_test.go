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

type fakePanel struct {
	ran  [][]string
	cmds [][]string // afk subcommands handed the terminal
}

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
		{Harness: "codex", Model: "gpt-6.1-sol", Effort: "medium", BenchmarkScore: f(76.4), BenchmarkName: "LMArena Agent #2", BenchmarkBasis: "measured", EffectiveScore: f(71.8), PoolHeadroomPct: f(52),
			ScoreParts: []engine.ScorePart{{Label: "plan headroom 52%", Points: 1.69}, {Label: "your ratings of 10 runs", Points: -6.29}}},
		{Harness: "claude", Model: "claude-fable-5-2", Effort: "high", BenchmarkScore: f(78.1), BenchmarkName: "LMArena Agent #1", BenchmarkBasis: "measured", EffectiveScore: f(80.6), PoolHeadroomPct: f(78),
			ScoreParts:     []engine.ScorePart{{Label: "plan headroom 78%", Points: 2.54}},
			BenchmarkParts: []engine.BenchPart{{Source: "lmarena", Label: "LMArena Agent #1", Score: 98, Weight: 1}, {Source: "swebench", Label: "SWE-bench Verified #3 (74.2)", Score: 95.7, Weight: 1, Carried: true}, {Source: "aider", Label: "Aider Polyglot #9 (61)", Score: 90.3, Weight: 0}}},
		{LaunchClass: "claude-local", Engine: "ollama", Model: "qwen36-14b", BenchmarkScore: f(51), EffectiveScore: f(51)},
	}, Sources: []BenchSource{
		{Key: "bench.sources.lmarena.enabled", Name: "LMArena", Measures: "rank on human-vote boards", UsedFor: "complex, review, webdev", On: true, Read: true, Status: "agent live, webdev live", About: "LMArena's leaderboards."},
		{ID: "swebench", Key: "bench.sources.swebench.enabled", Name: "SWE-bench Verified", Measures: "% of real issues solved", UsedFor: "complex, standard", On: true, Read: true, Weight: "1", Status: "80 models, 0 matched", About: "Real GitHub issues."},
		{ID: "my-evals", Key: "bench.custom.my-evals.enabled", Name: "my-evals", Own: true, Where: "https://example.com/board.json", Measures: "", UsedFor: "review", On: true, Read: true, Weight: "review 2", About: "Your own source."},
	}}, nil
}

func (fakePanel) Status(context.Context) (*StatusView, error) {
	now := time.Date(2026, 11, 27, 3, 31, 0, 0, time.UTC)
	return &StatusView{Updated: now,
		Plans: []PlanRow{
			{Harness: "claude", Plan: "Claude plan", FiveHour: f(71), Week: f(64), SignIn: "signed in"},
			{Harness: "codex", Plan: "ChatGPT plan", FiveHour: f(52), Week: f(80), SignIn: "signed in"},
			{Harness: "grok", Plan: "Grok plan", FiveHour: f(91), SignIn: "login on disk"},
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

func (p *fakePanel) ConfigSet(_ context.Context, key, value string) (string, error) {
	p.ran = append(p.ran, []string{"config-set", key, value})
	return key + " = " + value + " saved", nil
}

func (p *fakePanel) ConfigRemove(_ context.Context, section string) (string, error) {
	p.ran = append(p.ran, []string{"config-remove", section})
	return section + " removed", nil
}

func (p *fakePanel) ClearMarks(context.Context) (string, error) {
	p.ran = append(p.ran, []string{"clear-marks"})
	return "Cleared xai-grok.", nil
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

func (p *fakePanel) BenchDo(_ context.Context, op string, args ...string) (string, error) {
	p.ran = append(p.ran, append([]string{"bench", op}, args...))
	return "did " + op, nil
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

func (p *fakePanel) Command(args ...string) []string {
	p.cmds = append(p.cmds, args)
	return append([]string{"afk"}, args...)
}

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
		TabHarnesses: {"1 Route  2 Harnesses  3 Benchmarks  4 Skills  5 MCP  6 Usage  7 Config", "Harnesses  the agent CLIs on this machine", "INSTALLED  4", "▌CL claude        2.1.332   ● signed in",
			"OC opencode      1.4.0     ● signed out", "NOT INSTALLED  1", "PI pi", "Installed native installer · /usr/local/bin/claude", "Usage     5h 71% left · week 64% left", "D discover now", "u update"},
		TabBench:  {"Leaderboard   Sources   Why AFK picks", "‹coding›", "scored by  SWE-bench Verified", "1  claude-fable-5-2    CL", "78.1  measured  14✓ 2~", "CX OC", "qwen36-14b          OL", "AFK would pick for coding right now", "claude-fable-5-2 · high   effective 80.6 = benchmark 78.1 + 2.5", "runner-up CX gpt-6.1-sol 71.8 · 8.8 behind", "←→ task"},
		TabRuns:   {"Usage  what is left on each plan", "Plans", "Gateways & local models", "Run history", "updated 03:31", "CL Claude plan", "71%", "GK Grok plan", "week   unknown", "SET ASIDE  none", "←→ plan"},
		TabConfig: {"file ~/.config/afk/config.toml", "Routing", "Prefer                      balanced", "e edit config.toml"},
		TabSkills: {"4 skills · central ~/.config/afk/skills · 1 edited · 1 to sync · 1 to choose", "scope", "everywhere", "◆", "skill", "CL  CX  GK  AG", "gh-pr-triage", "↻", "space on/off"},
		TabMCP: {"4 servers · ~/.config/afk/mcp.toml · 360 tools · 1 edited · 1 to sync", "server         how               tools health       CL  CX  GK  PI", "openconnector  gateway homelab   312   ● up 2h ago",
			"○ untested", "╭─ openconnector", "tested    ● up 2h ago · 312 tools", "CL claude  ✓ written by AFK, in sync", "t test"},
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
		if !strings.Contains(strings.Split(s, "\n")[23], "ctrl+p commands") {
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
	// The box follows the selection; the heading still counts the edit.
	do(tea.KeyPressMsg{Code: tea.KeyUp})
	if s := panelText(p); strings.Contains(s, "changed in grok") || !strings.Contains(s, "╭─ humanizer") || !strings.Contains(s, "1 edited") {
		t.Errorf("the box should be humanizer's:\n%s", s)
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
		t.Fatal("6 didn't open Usage")
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
	p.Update(key("["))
	p.Update(tea.WindowSizeMsg{Width: 80, Height: 12})
	for range 10 {
		p.Update(key("down"))
	}
	s := panelText(p)
	if n := strings.Count(s, "\n") + 1; n != 12 || !strings.Contains(s, "▌") || !strings.Contains(s, "ctrl+p commands") {
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
	for _, w := range []string{"1 to choose", "prox-ops-deploy", "project", "project skills from ~/repos/prox-ops/.agents/skills"} {
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
	if strings.Contains(panelText(p), "github") {
		t.Errorf("other rows push the question off screen:\n%s", panelText(p))
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
	for _, w := range []string{"1 to choose", "repo-db", "project", "project servers from ~/repos/prox-ops/.mcp.json"} {
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
	// t and ↵ go to the project's server, not mcp.toml's.
	if cmd := p.Update(key("t")); cmd != nil {
		p.Update(cmd())
	}
	if got := strings.Join(src.ran[len(src.ran)-1], " "); got != "mcp project:test repo-db" {
		t.Errorf("t ran %q", got)
	}
	if cmd := p.Update(key("enter")); cmd != nil {
		p.Update(cmd())
	}
	if got := strings.Join(src.ran[len(src.ran)-1], " "); got != "mcp tools project:repo-db" {
		t.Errorf("enter ran %q", got)
	}
	p.tools = nil
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

// A plan a failed run set aside says so on the Usage tab, and c clears the
// mark in place. With nothing set aside there is no c.
func TestRunsTabClearsFailedRunMarks(t *testing.T) {
	src := &fakePanel{}
	now := func() time.Time { return time.Date(2026, 11, 27, 3, 31, 0, 0, time.UTC) }
	p := NewPanel(context.Background(), src, NewTheme(true), TabRuns, "", now)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 24})
	p.Update(p.Init()())
	if strings.Contains(panelText(p), "clear set-aside") {
		t.Fatalf("a clear key with nothing set aside:\n%s", panelText(p))
	}
	if cmd := p.Update(tea.KeyPressMsg{Code: 'c', Text: "c"}); cmd != nil || len(src.ran) != 0 {
		t.Fatalf("c ran %v with nothing set aside", src.ran)
	}
	p.data.status.Plans[2].SetAside = true
	p.data.status.Plans[2].Note = "set aside after a run failed with a rate-limit or quota error, for another 42m; this is not a usage reading"
	s := panelText(p)
	if !strings.Contains(s, "for another 42m") || !strings.Contains(s, "c clear set-aside") {
		t.Fatalf("no set-aside note or key:\n%s", s)
	}
	cmd := p.Update(tea.KeyPressMsg{Code: 'c', Text: "c"})
	if cmd == nil {
		t.Fatal("c did nothing")
	}
	p.Update(cmd())
	if len(src.ran) != 1 || src.ran[0][0] != "clear-marks" || p.notice != "Cleared xai-grok." {
		t.Fatalf("ran %v, notice %q", src.ran, p.notice)
	}
}

// A switch with something to agree to asks before it turns on: enter
// shows the warning, a second enter saves, anything else leaves it off.
// Turning it off asks nothing.
func TestConfigSwitchAsksBeforeTurningOn(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabConfig, "", time.Now)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 24})
	p.Update(p.Init()())
	set := func(v string) {
		p.raw.config = &ConfigView{Path: "c", Exists: true,
			Rows: [][2]string{{"harness.claude.vendor_usage", v}},
			Edit: map[string]ConfigEdit{"harness.claude.vendor_usage": {Choices: []string{"on", "off"}, Confirm: "reads the saved login"}}}
		p.data.config = p.raw.config
	}
	set("off")
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	if cmd := p.Update(enter); cmd != nil || len(src.ran) != 0 {
		t.Fatalf("the first enter saved: %v", src.ran)
	}
	if s := panelText(p); !strings.Contains(s, "reads the saved login") || !strings.Contains(s, "↵ turn on") || !strings.Contains(s, "esc leave off") {
		t.Fatalf("the question:\n%s", s)
	}
	// On a short screen with many rows the question is still in sight.
	long := *p.raw.config
	long.Rows = nil
	for i := 0; i < 30; i++ {
		long.Rows = append(long.Rows, [2]string{fmt.Sprintf("route.row%d", i), "x"})
	}
	long.Rows = append(long.Rows, [2]string{"harness.claude.vendor_usage", "off"})
	saved, savedSel := p.data.config, p.sel[TabConfig]
	p.data.config, p.sel[TabConfig] = &long, 30
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 12})
	if s := panelText(p); !strings.Contains(s, "reads the saved login") || !strings.Contains(s, "harness.claude.vendor_usage") {
		t.Fatalf("the question is out of sight on a short screen:\n%s", s)
	}
	p.data.config, p.sel[TabConfig] = saved, savedSel
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 24})
	// q is an answer here (no), not quit.
	if cmd := p.Update(tea.KeyPressMsg{Code: 'q', Text: "q"}); cmd != nil || p.quit || len(src.ran) != 0 || p.cfgAskKey != "" {
		t.Fatalf("another key must leave it off: ran %v quit %v", src.ran, p.quit)
	}
	p.Update(enter)
	cmd := p.Update(enter)
	if cmd == nil {
		t.Fatal("the second enter did nothing")
	}
	cmd()
	if got := src.ran[len(src.ran)-1]; got[1] != "harness.claude.vendor_usage" || got[2] != "on" {
		t.Fatalf("saved %v", got)
	}
	set("on")
	n := len(src.ran)
	if cmd := p.Update(enter); cmd == nil {
		t.Fatal("turning it off asked")
	} else if cmd(); len(src.ran) != n+1 || src.ran[n][2] != "off" {
		t.Fatalf("saved %v", src.ran)
	}
}

// The Config tab changes settings in place: enter steps a choice and
// saves it, a typed value gets an input, and a row with no form says so.
func TestConfigTabEdits(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabConfig, "", time.Now)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 24})
	p.Update(p.Init()())
	p.raw.config = &ConfigView{Path: "~/.config/afk/config.toml", Exists: true,
		Rows: [][2]string{{"route.prefer", "balanced"}, {"route.pacing", "off"}, {"trust.repos", "1 trusted"}, {"gateway", "none"}},
		Edit: map[string]ConfigEdit{
			"route.prefer": {Choices: []string{"balanced", "cheap", "best"}},
			"route.pacing": {Choices: []string{"on", "off"}},
			"trust.repos":  {Value: "~/a", Hint: "folders, separated by commas"},
		}}
	p.data.config = p.raw.config
	if !strings.Contains(panelText(p), "↵ change") {
		t.Fatalf("no change key:\n%s", panelText(p))
	}
	press := func(k tea.KeyPressMsg) tea.Cmd { return p.Update(k) }
	enter, down := tea.KeyPressMsg{Code: tea.KeyEnter}, tea.KeyPressMsg{Code: tea.KeyDown}

	cmd := press(enter)
	if cmd == nil {
		t.Fatal("enter on a choice did nothing")
	}
	cmd() // the save; the reload that follows isn't run here
	if got := src.ran[len(src.ran)-1]; got[0] != "config-set" || got[1] != "route.prefer" || got[2] != "cheap" {
		t.Fatalf("saved %v", got)
	}
	if cmd := press(tea.KeyPressMsg{Code: tea.KeyLeft}); cmd == nil {
		t.Fatal("left did nothing")
	} else if cmd(); src.ran[len(src.ran)-1][2] != "best" {
		t.Fatalf("left steps back around: %v", src.ran[len(src.ran)-1])
	}
	press(down)
	if cmd := press(enter); cmd == nil {
		t.Fatal("enter on a switch did nothing")
	} else if cmd(); src.ran[len(src.ran)-1][2] != "on" {
		t.Fatalf("off steps to on: %v", src.ran[len(src.ran)-1])
	}

	// A typed value: the input opens with the current one.
	press(down)
	n := len(src.ran)
	if cmd := press(enter); cmd != nil || p.cfgKey != "trust.repos" || p.cfgText != "~/a" {
		t.Fatalf("typing didn't start: key %q text %q", p.cfgKey, p.cfgText)
	}
	if s := panelText(p); !strings.Contains(s, "~/a▏") || !strings.Contains(s, "↵ save") || !strings.Contains(s, "folders, separated by commas") {
		t.Fatalf("the input row:\n%s", s)
	}
	for _, r := range ", ~/b" {
		k := tea.KeyPressMsg{Code: r, Text: string(r)}
		if r == ' ' {
			k = tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
		}
		press(k)
	}
	press(tea.KeyPressMsg{Code: 'q', Text: "q"}) // typed, not quit
	press(tea.KeyPressMsg{Code: tea.KeyBackspace})
	if p.quit || p.cfgText != "~/a, ~/b" {
		t.Fatalf("text %q quit %v", p.cfgText, p.quit)
	}
	cmd = press(enter)
	if cmd == nil || p.cfgKey != "" {
		t.Fatal("enter didn't save the typed value")
	}
	cmd()
	if got := src.ran[len(src.ran)-1]; len(src.ran) != n+1 || got[1] != "trust.repos" || got[2] != "~/a, ~/b" {
		t.Fatalf("saved %v", got)
	}
	// esc drops what was typed.
	press(enter)
	press(tea.KeyPressMsg{Code: 'x', Text: "x"})
	press(tea.KeyPressMsg{Code: tea.KeyEscape})
	if p.cfgKey != "" || len(src.ran) != n+1 || p.back || p.quit {
		t.Fatal("esc while typing cancels only the typing")
	}

	// A row with no form yet.
	press(down)
	if cmd := press(tea.KeyPressMsg{Code: 'x', Text: "x"}); cmd != nil || p.notice != "" {
		t.Fatal("x on a row with nothing to remove did something")
	}
	if cmd := press(enter); cmd != nil || !strings.Contains(p.notice, "can't be changed here yet") {
		t.Fatalf("notice %q", p.notice)
	}
}

// An action's result reaches the tabs when they were opened from the
// composer, not only when the panel runs on its own.
func TestComposerPanelGetsActionResults(t *testing.T) {
	m, _ := composeModel(t, 100, false)
	src := &fakePanel{}
	m.opt.Panel = src
	_, cmd := m.Update(key("7"))
	if m.panel == nil || m.panel.tab != TabConfig {
		t.Fatal("7 didn't open the Config tab")
	}
	m.Update(cmd())
	m.panel.raw.config.Edit = map[string]ConfigEdit{"route.prefer": {Choices: []string{"balanced", "cheap"}}}
	m.panel.data.config = m.panel.raw.config
	_, cmd = m.Update(key("enter"))
	if cmd == nil {
		t.Fatal("enter did nothing")
	}
	_, reload := m.Update(cmd())
	if m.panel.notice != "route.prefer = cheap saved" || reload == nil {
		t.Fatalf("the save's result didn't reach the tab: notice %q", m.panel.notice)
	}
	for _, msg := range []tea.Msg{mcpDoneMsg{text: "mcp ok"}, skillsDoneMsg{text: "skills ok"}, marksClearedMsg{text: "marks ok"}} {
		m.Update(msg)
		want := map[string]bool{"mcp ok": true, "skills ok": true, "marks ok": true}
		if !want[m.panel.notice] {
			t.Fatalf("%T didn't reach the tab: notice %q", msg, m.panel.notice)
		}
	}
}

// x removes the gateway a row belongs to, only when pressed twice in a row.
func TestConfigTabRemovesAGateway(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabConfig, "", time.Now)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 24})
	p.Update(p.Init()())
	p.raw.config = &ConfigView{Exists: true,
		Rows: [][2]string{{"gateway.work.url", "gw.example"}, {"gateway.work.key", "env:K"}},
		Edit: map[string]ConfigEdit{"gateway.work.url": {Value: "https://gw.example", Remove: "gateway.work"}, "gateway.work.key": {Value: "env:K", Remove: "gateway.work"}}}
	p.data.config = p.raw.config
	x := tea.KeyPressMsg{Code: 'x', Text: "x"}
	if !strings.Contains(panelText(p), "x remove gateway.work") {
		t.Fatalf("no remove key:\n%s", panelText(p))
	}
	if cmd := p.Update(x); cmd != nil || !strings.Contains(p.notice, "press x again") {
		t.Fatalf("first x: notice %q", p.notice)
	}
	p.Update(tea.KeyPressMsg{Code: tea.KeyDown}) // anything else disarms it
	if cmd := p.Update(x); cmd != nil || len(src.ran) != 0 {
		t.Fatal("x after another key removed at once")
	}
	cmd := p.Update(x)
	if cmd == nil {
		t.Fatal("the second x did nothing")
	}
	p.Update(cmd())
	if got := src.ran[len(src.ran)-1]; got[0] != "config-remove" || got[1] != "gateway.work" || p.notice != "gateway.work removed" {
		t.Fatalf("ran %v, notice %q", got, p.notice)
	}
}

// a on the MCP tab and n on the Skills tab ask for one line and hand it
// to the action; esc drops it, and every key is text while it is open.
func TestTabsAskForANewServerAndSkill(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabMCP, "", time.Now)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	p.Update(p.Init()())
	typ := func(s string) {
		for _, r := range s {
			k := tea.KeyPressMsg{Code: r, Text: string(r)}
			if r == ' ' {
				k = tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
			}
			p.Update(k)
		}
	}
	p.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	if p.ask == nil {
		t.Fatal("a didn't ask for the server")
	}
	typ("docs https://docs.example/mcp q")
	if p.quit {
		t.Fatal("q quit while typing")
	}
	if s := panelText(p); !strings.Contains(s, "new server docs https://docs.example/mcp q▏") || !strings.Contains(s, "↵ save") || !strings.Contains(s, "via:work") || strings.Contains(s, "q quit") {
		t.Fatalf("the input:\n%s", s)
	}
	p.Update(tea.KeyPressMsg{Code: tea.KeyBackspace})
	p.Update(tea.KeyPressMsg{Code: tea.KeyBackspace})
	cmd := p.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil || p.ask != nil {
		t.Fatal("enter didn't hand the line on")
	}
	cmd()
	if got := src.ran[len(src.ran)-1]; got[1] != "add" || got[2] != "docs https://docs.example/mcp" {
		t.Fatalf("ran %v", got)
	}
	n := len(src.ran)
	p.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	typ("x")
	if p.Update(tea.KeyPressMsg{Code: tea.KeyEscape}); p.ask != nil || p.back || p.quit || len(src.ran) != n {
		t.Fatal("esc while typing cancels only the typing")
	}

	p = NewPanel(context.Background(), src, NewTheme(true), TabSkills, "", time.Now)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	p.Update(p.Init()())
	p.Update(tea.KeyPressMsg{Code: 'n', Text: "n"})
	for _, r := range "pr-triage Use when sorting pull requests." {
		k := tea.KeyPressMsg{Code: r, Text: string(r)}
		if r == ' ' {
			k = tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
		}
		p.Update(k)
	}
	cmd = p.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("enter didn't make the skill")
	}
	cmd()
	if got := src.ran[len(src.ran)-1]; got[1] != "new" || got[2] != "pr-triage" || got[3] != "Use when sorting pull requests." {
		t.Fatalf("ran %v", got)
	}
}

// A long reported tier is shown in full on its card.
func TestUsagePlanCardShowsLongTier(t *testing.T) {
	p := NewPanel(context.Background(), &fakePanel{}, NewTheme(true), TabRuns, "", nil)
	p.data.status = &StatusView{Plans: []PlanRow{
		{Harness: "codex", Plan: "ChatGPT plan · enterprise", FiveHour: f(52), Week: f(80), SignIn: "signed in"},
		{Harness: "claude", Plan: "Claude plan", Week: f(95), NoFiveHour: true, SignIn: "signed in", Pace: "~40% may go unused, so AFK leans to it", Leans: true, RunsToday: 3},
	}}
	p.width = 100
	lines, _ := p.usageLines(100)
	var s []string
	for _, l := range lines {
		if l.width() > 100 {
			t.Errorf("line over 100 cells: %q", l.plain())
		}
		s = append(s, l.plain())
	}
	text := strings.Join(s, "\n")
	for _, want := range []string{"ChatGPT plan · enterprise", "5-hour no limit on this plan", "may go unused", "3 runs today", "52%"} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in\n%s", want, text)
		}
	}
}

// [ and ] switch the Usage views; each has its own rows.
func TestUsageViews(t *testing.T) {
	p := panelAt(t, TabRuns)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	p.Update(key("]"))
	s := panelText(p)
	for _, want := range []string{"GATEWAY", "agentgateway", "└ VL vLLM", "LOCAL ENGINES", "this PC · RTX 5090 · 1 model", "models    qwen36-14b"} {
		if !strings.Contains(s, want) {
			t.Errorf("engines: missing %q in\n%s", want, s)
		}
	}
	p.Update(key("]"))
	p.Update(key("down"))
	s = panelText(p)
	for _, want := range []string{"started", "claude-fable-5-2", "solved", "! exit 1", "╭─ r-7f1a", "gpt-6.1-sol", "took 8m"} {
		if !strings.Contains(s, want) {
			t.Errorf("runs: missing %q in\n%s", want, s)
		}
	}
	p.Update(key("]"))
	if p.viewOf(TabRuns) != usagePlans || p.sel[TabRuns] != 0 {
		t.Errorf("] didn't wrap to Plans: view %d sel %d", p.viewOf(TabRuns), p.sel[TabRuns])
	}
	p.Update(key("right"))
	if p.sel[TabRuns] != 1 {
		t.Errorf("→ didn't pick the next plan: %d", p.sel[TabRuns])
	}
}

func TestSignInState(t *testing.T) {
	for in, want := range map[string][2]string{
		"":              {"", "not reported"},
		"unknown":       {"", "not reported"},
		"signed out":    {"bad", "signed out"},
		"token expired": {"bad", "token expired"},
		"login on disk": {"partly", "login on disk"},
		"signed in":     {"ok", "signed in"},
	} {
		st, txt := signInState(HarnessRow{SignIn: in})
		if st != want[0] || txt != want[1] {
			t.Errorf("signInState(%q) = %q, %q; want %q, %q", in, st, txt, want[0], want[1])
		}
	}
}

func TestHarnessesWide(t *testing.T) {
	p := panelAt(t, TabHarnesses)
	p.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	var row string
	for _, l := range strings.Split(panelText(p), "\n") {
		if strings.Contains(l, "▌CL claude") {
			row = l
		}
	}
	if !strings.Contains(row, " │ ") || !strings.Contains(row, "claude") {
		t.Fatalf("want the detail beside the list at 120 columns, got %q\n%s", row, panelText(p))
	}
	for _, want := range []string{"auto discovery  ○ off  A turn on", "Models    claude-fable-5-2, sonnet, +2 via gateway", "Updates"} {
		if !strings.Contains(panelText(p), want) {
			t.Errorf("missing %q in\n%s", want, panelText(p))
		}
	}
	for _, l := range p.Lines() {
		if n := l.width(); n > 120 {
			t.Errorf("line is %d cells wide, over 120: %q", n, l.plain())
		}
	}
}

func TestSkillsDriftBox(t *testing.T) {
	p := panelAt(t, TabSkills)
	p.Update(key("down")) // gh-pr-triage, edited in grok
	s := panelText(p)
	for _, want := range []string{"╭─ gh-pr-triage changed in grok", "Edited in ~/.grok/skills 2 hours ago. 4 lines differ from central.", "k keep grok's and update central"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in\n%s", want, s)
		}
	}
}

func TestMCPDriftBoxAndImport(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabMCP, "", nil)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 40})
	p.Update(p.Init()())
	p.Update(key("down")) // github, edited in codex
	s := panelText(p)
	for _, want := range []string{"╭─ github changed in codex", "k keep codex's as its own"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in\n%s", want, s)
		}
	}
	if cmd := p.Update(key("i")); cmd != nil || !strings.Contains(p.notice, "Nothing to import") {
		t.Errorf("i with nothing found: notice %q", p.notice)
	}
	p.data.mcp.Found = []MCPFound{
		{Name: "linear", In: []string{"codex"}, Where: "https://mcp.linear.app/mcp"},
		{Name: "sentry", In: []string{"claude", "codex"}, Where: "npx sentry-mcp", Left: []string{"env SENTRY_TOKEN (its value is written in the file)"}},
		{Name: "old", In: []string{"claude"}, Why: "an sse server; AFK copies stdio and http servers"},
	}
	s = panelText(p)
	for _, want := range []string{"Found in your CLIs' own configs: 3 servers", "linear", "https://mcp.linear.app/mcp", "not copied: env SENTRY_TOKEN", "can't import: an sse server", "i adds all 2 to mcp.toml", "i import"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in\n%s", want, s)
		}
	}
	cmd := p.Update(key("i"))
	if cmd == nil {
		t.Fatal("i didn't import")
	}
	cmd()
	if got := strings.Join(src.ran[len(src.ran)-1], " "); got != "mcp import" {
		t.Errorf("ran %q", got)
	}
}

func TestBenchViews(t *testing.T) {
	src := &fakePanel{}
	p := NewPanel(context.Background(), src, NewTheme(true), TabBench, "", nil)
	p.Update(tea.WindowSizeMsg{Width: 110, Height: 40})
	p.Update(p.Init()())
	for _, l := range p.Lines() {
		if l.width() > 110 {
			t.Errorf("line over 110 cells: %q", l.plain())
		}
	}
	p.Update(key("]"))
	s := panelText(p)
	for _, want := range []string{"LMArena", "rank on human-vote boards", "SWE-bench Verified", "my-evals ·yours", "per task", "setting   bench.sources.lmarena.enabled = on", "space turns it off", "averages their scores by weight"} {
		if !strings.Contains(s, want) {
			t.Errorf("sources: missing %q in\n%s", want, s)
		}
	}
	cmd := p.Update(key(" "))
	if cmd == nil {
		t.Fatal("space didn't toggle the source")
	}
	cmd()
	// LMArena isn't blended by weight here, so w says so.
	if p.Update(key("w")) != nil || !strings.Contains(p.notice, "has no weight") {
		t.Errorf("w on LMArena: %q", p.notice)
	}
	p.Update(key("down"))
	s = panelText(p)
	for _, want := range []string{"weight    1", "w changes it", "t reads it now", "80 models, 0 matched"} {
		if !strings.Contains(s, want) {
			t.Errorf("swebench box: missing %q in\n%s", want, s)
		}
	}
	p.Update(key("w"))
	for _, k := range []string{"2", "space", "r", "e", "v", "i", "e", "w"} {
		p.Update(key(k))
	}
	cmd = p.Update(key("enter"))
	cmd()
	if got := strings.Join(src.ran[len(src.ran)-1], " "); got != "bench weight swebench 2 review" {
		t.Errorf("weight ran %q", got)
	}
	if p.Update(key("x")) != nil || !strings.Contains(p.notice, "built in") {
		t.Errorf("x on a built-in: %q", p.notice)
	}
	p.Update(key("down"))
	s = panelText(p)
	if !strings.Contains(s, "x removes it") || !strings.Contains(s, "from      https://example.com/board.json") {
		t.Errorf("own box:\n%s", s)
	}
	if p.Update(key("x")) != nil || !strings.Contains(p.notice, "press x again") {
		t.Errorf("first x: %q", p.notice)
	}
	cmd = p.Update(key("x"))
	if cmd == nil {
		t.Fatal("second x didn't remove")
	}
	cmd()
	if got := strings.Join(src.ran[len(src.ran)-1], " "); got != "bench rm my-evals" {
		t.Errorf("rm ran %q", got)
	}
	p.Update(key("a"))
	for _, r := range "x https://e.com/b.csv complex" {
		k := string(r)
		if k == " " {
			k = "space"
		}
		p.Update(key(k))
	}
	cmd = p.Update(key("enter"))
	cmd()
	if got := strings.Join(src.ran[len(src.ran)-1], " "); got != "bench add x https://e.com/b.csv complex" {
		t.Errorf("add ran %q", got)
	}
	p.Update(key("up"))
	p.Update(key("up"))
	p.Update(key("]"))
	p.Update(key("down"))
	s = panelText(p)
	for _, want := range []string{"1  CL claude-fable-5-2 · high", "80.6  ← AFK's pick", "2  CX gpt-6.1-sol · medium", "-4.6", "Why gpt-6.1-sol scores 71.8 for coding", "benchmark   76.4  LMArena Agent #2 (measured)", "-6.3  your ratings of 10 runs", "effective   71.8  #2 of 3"} {
		if !strings.Contains(s, want) {
			t.Errorf("why: missing %q in\n%s", want, s)
		}
	}
	p.Update(key("up"))
	s = panelText(p)
	for _, want := range []string{"weighted average of 3 sources (measured)", "98.0  LMArena Agent #1  × 1", "95.7  SWE-bench Verified #3 (74.2)  × 1 · last sync", "90.3  Aider Polyglot #9 (61)  × 0, left out"} {
		if !strings.Contains(s, want) {
			t.Errorf("why parts: missing %q in\n%s", want, s)
		}
	}
}

func TestSplitArgs(t *testing.T) {
	got := splitArgs(`my-evals "/home/me/My Boards/r.csv" review`)
	if len(got) != 3 || got[1] != "/home/me/My Boards/r.csv" {
		t.Errorf("%q", got)
	}
}

// An engine without the Anthropic Messages API is shown, never as usable,
// with the way to use it.
func TestUsageEngineWithoutAPI(t *testing.T) {
	p := panelAt(t, TabRuns)
	p.data.status.Engines = append(p.data.status.Engines, EngineRow{Engine: "tabbyapi", Where: "this PC", Models: []string{"Qwen3.6-27B-exl3"}, NoAPI: true})
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	p.Update(key("]"))
	p.Update(key("down"))
	s := panelText(p)
	for _, want := range []string{"TA TabbyAPI", "no API", "this PC · 1 model · needs a gateway", "has no Anthropic Messages API", "Put a gateway in front of it"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in\n%s", want, s)
		}
	}
}
