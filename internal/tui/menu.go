package tui

import (
	"sort"
	"strings"
)

// The command menu. Typing / in the composer opens it under the input
// bar, the way Claude Code's and Codex's do: every command with what it
// does, narrowed as you type, ↑↓ to pick, tab to complete, ↵ to run. Once
// a command that takes a value is complete, the menu lists its values.
// ctrl+p opens the same list on the tabs.

// slashCmd is one command the menu offers.
type slashCmd struct {
	name, args, desc string
	tab              Tab  // the tab it opens (-1: none)
	needsArg         bool // ↵ completes it rather than running it bare
	// values are what can follow it; nil takes free text.
	values func(m *Model) []string
	// panel says the command is offered on the tabs too.
	panel bool
}

const noTab Tab = -1

// slashCmds are the composer's commands, in the order the menu lists them.
func slashCmds() []slashCmd {
	cmds := []slashCmd{}
	for i := TabHarnesses; i <= TabAPI; i++ {
		name := strings.ToLower(tabNames[i])
		if i == TabBench {
			name = "bench"
		}
		cmds = append(cmds, slashCmd{name: name, desc: tabNames[i] + " · " + tabBlurbs[i], tab: i, panel: true})
	}
	return append(cmds,
		slashCmd{name: "update", args: "[cli|all]", desc: "update the agent CLIs (all, or one), or AFK itself", tab: noTab, panel: true,
			values: func(m *Model) []string { return append([]string{"all", "afk"}, m.harnessNames()...) }},
		slashCmd{name: "harness", args: "<cli>", desc: "send the next tasks to one CLI (empty: let AFK pick)", tab: noTab, needsArg: true,
			values: func(m *Model) []string { return m.harnessNames() }},
		slashCmd{name: "model", args: "<model>", desc: "pin a model for the next tasks", tab: noTab, needsArg: true,
			values: func(m *Model) []string { return m.modelNames() }},
		slashCmd{name: "effort", args: "<level>", desc: "pin the effort level", tab: noTab, needsArg: true,
			values: func(m *Model) []string { return m.effortNames() }},
		slashCmd{name: "prefer", args: "<mode>", desc: "balanced, cheap or best routes", tab: noTab, needsArg: true,
			values: func(*Model) []string { return []string{"balanced", "cheap", "best"} }},
		slashCmd{name: "mode", args: "<mode>", desc: "what the CLI may do without asking, for this session", tab: noTab, needsArg: true,
			values: func(*Model) []string { return []string{"read-only", "ask", "edits", "auto"} }},
		slashCmd{name: "clear", desc: "unpin the CLI, model, effort and prefer mode", tab: noTab},
		slashCmd{name: "open", desc: "reopen the last run's session in its CLI", tab: noTab},
		slashCmd{name: "rate", args: "<1|2|3>", desc: "rate the last run: solved, partly, wrong pick", tab: noTab, needsArg: true,
			values: func(*Model) []string { return []string{"1", "2", "3"} }},
		slashCmd{name: "exit", desc: "leave AFK", tab: noTab},
	)
}

// menuItem is one row of the open menu: a command, or a value for one.
type menuItem struct {
	cmd   slashCmd
	value string // set when the row is a value
}

// menuItems is what the menu lists for the input as it stands; nil when
// the input isn't a command.
func (m *Model) menuItems() []menuItem {
	v := m.cin.Value()
	if !strings.HasPrefix(v, "/") || m.menuOff {
		return nil
	}
	name, arg, spaced := strings.Cut(strings.TrimPrefix(v, "/"), " ")
	if !spaced {
		return matchCmds(slashCmds(), name)
	}
	for _, c := range slashCmds() {
		if c.name != name || c.values == nil {
			continue
		}
		arg = strings.TrimSpace(arg)
		var out []menuItem
		for _, val := range c.values(m) {
			if strings.HasPrefix(val, arg) && val != arg {
				out = append(out, menuItem{cmd: c, value: val})
			}
		}
		return out
	}
	return nil
}

// matchCmds narrows commands to those whose name starts with q, then to
// those that contain it.
func matchCmds(cmds []slashCmd, q string) []menuItem {
	q = strings.ToLower(q)
	var exact, first, then []menuItem
	for _, c := range cmds {
		switch {
		case c.name == q:
			exact = append(exact, menuItem{cmd: c})
		case strings.HasPrefix(c.name, q):
			first = append(first, menuItem{cmd: c})
		case q != "" && (strings.Contains(c.name, q) || strings.Contains(strings.ToLower(c.desc), q)):
			then = append(then, menuItem{cmd: c})
		}
	}
	return append(append(exact, first...), then...)
}

// menuKey handles a key while the menu is open. done is false when the
// key isn't the menu's and goes on to the input.
func (m *Model) menuKey(key string) bool {
	items := m.menuItems()
	if len(items) == 0 {
		return false
	}
	m.menuSel = min(m.menuSel, len(items)-1)
	it := items[m.menuSel]
	switch key {
	case "up", "ctrl+p":
		m.menuSel = (m.menuSel - 1 + len(items)) % len(items)
		return true
	case "down", "ctrl+n":
		m.menuSel = (m.menuSel + 1) % len(items)
		return true
	case "tab":
		m.complete(it)
		return true
	case "esc":
		m.menuOff = true
		return true
	case "enter":
		// A command typed out in full runs as it is (/harness alone
		// unpins); a partial one is completed, and one that takes a
		// value waits for it.
		if m.cin.Value() == "/"+it.cmd.name && it.value == "" {
			return false
		}
		m.complete(it)
		return it.value == "" && it.cmd.needsArg
	}
	return false
}

// complete puts the item in the input: "/name " for a command that takes
// a value, "/name value" for a value.
func (m *Model) complete(it menuItem) {
	switch {
	case it.value != "":
		m.cin.SetValue("/" + it.cmd.name + " " + it.value)
	case it.cmd.args != "":
		m.cin.SetValue("/" + it.cmd.name + " ")
	default:
		m.cin.SetValue("/" + it.cmd.name)
	}
	m.cin.CursorEnd()
	m.menuSel = 0
}

// menuLines draws the open menu, at most menuRows rows, scrolled to keep
// the selection in view.
func (m *Model) menuLines(w int) []line {
	items := m.menuItems()
	if len(items) == 0 {
		return nil
	}
	t := m.theme
	sel := min(m.menuSel, len(items)-1)
	start := 0
	if sel >= menuRows {
		start = sel - menuRows + 1
	}
	nameW := 0
	for _, it := range items {
		nameW = max(nameW, lenCells(itemLabel(it)))
	}
	nameW = min(nameW+2, 26)
	var out []line
	for i := start; i < len(items) && i < start+menuRows; i++ {
		it := items[i]
		desc := it.cmd.desc
		if it.value != "" {
			desc = ""
		}
		row := line{sg(t.Accent, " "+col(itemLabel(it), nameW)), sg(t.Dim, desc)}
		if i == sel {
			row = append(line{sg(t.Accent, "▌")}, fitLine(row, w-1).pad(w-1, t.Plain).on(t.SelBG)...)
		} else {
			row = append(line{sg(t.Plain, " ")}, row...)
		}
		out = append(out, fitLine(row, w))
	}
	if more := len(items) - (start + menuRows); more > 0 {
		out = append(out, line{sg(t.Dim, "   …"+plural(more, "more", "more"))})
	}
	return out
}

const menuRows = 8

func itemLabel(it menuItem) string {
	if it.value != "" {
		return it.value
	}
	s := "/" + it.cmd.name
	if it.cmd.args != "" {
		s += " " + it.cmd.args
	}
	return s
}

// harnessNames are the CLIs the router knows here, for /harness and
// /update.
func (m *Model) harnessNames() []string {
	seen := map[string]bool{}
	var out []string
	if m.preview != nil {
		rows, _ := m.preview.Rows()
		for _, r := range rows {
			if r.Harness != "" && !seen[r.Harness] {
				seen[r.Harness] = true
				out = append(out, r.Harness)
			}
		}
	}
	sort.Strings(out)
	return out
}

func (m *Model) modelNames() []string {
	seen := map[string]bool{}
	var out []string
	if m.preview != nil {
		rows, _ := m.preview.Rows()
		for _, r := range rows {
			if r.Model != "" && !seen[r.Model] {
				seen[r.Model] = true
				out = append(out, r.Model)
			}
		}
	}
	return out
}

func (m *Model) effortNames() []string {
	seen := map[string]bool{}
	var out []string
	if m.preview != nil {
		rows, _ := m.preview.Rows()
		for _, r := range rows {
			for _, e := range r.SupportedEfforts {
				if !seen[e] {
					seen[e] = true
					out = append(out, e)
				}
			}
		}
	}
	if len(out) == 0 {
		out = []string{"low", "medium", "high"}
	}
	return out
}
