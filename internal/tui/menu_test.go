package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestComposerShowsTheTabs(t *testing.T) {
	m, _ := composeModel(t, 80, false)
	m.opt.Panel = &fakePanel{}
	s := ansi.Strip(m.Render())
	if !strings.Contains(s, "1 Route  2 Harnesses 3 Benchmarks 4 Skills 5 MCP 6 Usage 7 Config 8 API") {
		t.Fatalf("the tabs aren't in sight on the composer:\n%s", s)
	}
	// Without the panel (afk "task" mode) there is nothing to switch to.
	m.opt.Panel = nil
	if strings.Contains(ansi.Strip(m.Render()), "2 Harnesses") {
		t.Error("tabs shown with no panel behind them")
	}
}

func TestSlashMenu(t *testing.T) {
	m, _ := composeModel(t, 80, false)
	m.opt.Panel = &fakePanel{}
	typeText(m, "/")
	s := ansi.Strip(m.Render())
	for _, w := range []string{"/harnesses", "/config", "/update [cli|all]", "update the agent CLIs", "tab complete"} {
		if !strings.Contains(s, w) {
			t.Errorf("the menu lacks %q:\n%s", w, s)
		}
	}
	// It narrows as you type; tab completes a command that takes a value,
	// and then its values are listed.
	typeText(m, "eff")
	m.Update(key("tab"))
	if m.cin.Value() != "/effort " {
		t.Fatalf("tab completed to %q", m.cin.Value())
	}
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "high") {
		t.Fatalf("no effort values:\n%s", s)
	}
	m.Update(key("down"))
	m.Update(key("enter"))
	if m.opt.Flags.Effort == "" || m.cin.Value() != "" {
		t.Fatalf("↵ on a value didn't pin it: effort %q, input %q", m.opt.Flags.Effort, m.cin.Value())
	}
	// ↵ on a partial command that takes a value completes it and waits.
	typeText(m, "/pre")
	m.Update(key("enter"))
	if m.cin.Value() != "/prefer " {
		t.Fatalf("↵ on /pre left %q", m.cin.Value())
	}
	// esc closes the menu and leaves the text.
	m.Update(key("esc"))
	if m.menuItems() != nil || m.cin.Value() != "/prefer " {
		t.Fatalf("esc: menu %v, input %q", m.menuItems(), m.cin.Value())
	}
}

func TestSlashUpdateRunsTheUpdate(t *testing.T) {
	for in, want := range map[string]string{
		"/update":       "harness update --all",
		"/update all":   "harness update --all",
		"/update codex": "harness update codex",
		"/update afk":   "update",
	} {
		m, _ := composeModel(t, 80, false)
		src := &fakePanel{}
		m.opt.Panel = src
		m.cin.SetValue(in)
		m.menuOff = true
		_, cmd := m.Update(key("enter"))
		if cmd == nil || len(src.cmds) != 1 || strings.Join(src.cmds[0], " ") != want {
			t.Errorf("%s ran %v, want %q", in, src.cmds, want)
		}
	}
}

func TestPanelPalette(t *testing.T) {
	src := &fakePanel{}
	p := panelAt(t, TabHarnesses)
	p.src = src
	p.Update(tea.KeyPressMsg{Code: 'p', Mod: tea.ModCtrl})
	if p.pal == nil {
		t.Fatal("ctrl+p didn't open the palette")
	}
	s := panelText(p)
	for _, w := range []string{"Commands", "Go to Config", "Update all agent CLIs", "Update claude"} {
		if !strings.Contains(s, w) {
			t.Errorf("palette lacks %q:\n%s", w, s)
		}
	}
	for _, r := range "cnfg" {
		p.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	p.Update(key("enter"))
	if p.pal != nil || p.tab != TabConfig {
		t.Fatalf("“cnfg” ↵ went to %s", tabNames[p.tab])
	}
	p.Update(tea.KeyPressMsg{Code: ':', Text: ":"})
	for _, r := range "update all" {
		p.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	if cmd := p.Update(key("enter")); cmd == nil || len(src.cmds) != 1 || strings.Join(src.cmds[0], " ") != "harness update --all" {
		t.Fatalf("update all ran %v", src.cmds)
	}
	// U on the Harnesses tab updates every CLI.
	p.switchTo(TabHarnesses)
	src.cmds = nil
	if cmd := p.Update(tea.KeyPressMsg{Code: 'U', Text: "U"}); cmd == nil || len(src.cmds) != 1 || strings.Join(src.cmds[0], " ") != "harness update --all" {
		t.Fatalf("U ran %v", src.cmds)
	}
}

func TestConfigGroupsAndExplains(t *testing.T) {
	p := panelAt(t, TabConfig)
	p.Update(tea.WindowSizeMsg{Width: 110, Height: 30})
	s := panelText(p)
	for _, w := range []string{"Routing", "Gateways", "Prefer", "How AFK weighs quality against cost", "route.prefer"} {
		if !strings.Contains(s, w) {
			t.Errorf("config lacks %q:\n%s", w, s)
		}
	}
	// Each group is listed once, whatever order the rows came in.
	v := &ConfigView{Rows: [][2]string{{"trust.repos", "0"}, {"route.prefer", "x"}, {"permissions.default", "ask"}, {"route.learn", "on"}}}
	sortConfig(v)
	var got []string
	for _, r := range v.Rows {
		got = append(got, r[0])
	}
	if strings.Join(got, ",") != "route.prefer,route.learn,trust.repos,permissions.default" {
		t.Errorf("order %v", got)
	}
}
