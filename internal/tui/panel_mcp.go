package tui

import (
	"fmt"

	tea "charm.land/bubbletea/v2"
)

// MCPView is the MCP tab: every server in mcp.toml in every CLI.
type MCPView struct {
	Source      string   // mcp.toml, as people read it
	Cols        []string // CLIs AFK writes MCP servers into
	Unsupported []string // installed CLIs with no MCP config AFK knows
	Rows        []MCPRow
	Drift       []MCPDrift
	Pending     int
	Problems    []string
}

// MCPRow is one server. Cells holds the mcp package's cell names by CLI:
// synced, pending, drifted, off, conflict, removing, orphan, unmanaged,
// unsupported, error.
type MCPRow struct {
	Name   string
	Via    string // stdio, http or a gateway's name
	Listed bool
	Tools  int    // from the last test; -1 untested
	Status string // up, down, untested
	Tested string // "2h ago"
	Cells  map[string]string
	Notes  map[string]string // why a cell is unsupported, by CLI
}

// MCPDrift is an entry edited in a CLI since AFK wrote it.
type MCPDrift struct{ Server, Harness, File string }

func mcpMark(c string) string {
	switch c {
	case "unsupported":
		return "–"
	case "error":
		return "?"
	}
	return skillMark(c)
}

func (p *Panel) mcpAt() (MCPRow, string, bool) {
	v := p.data.mcp
	if v == nil || len(v.Rows) == 0 || len(v.Cols) == 0 {
		return MCPRow{}, "", false
	}
	return v.Rows[min(p.sel[TabMCP], len(v.Rows)-1)], v.Cols[min(p.mcpCol, len(v.Cols)-1)], true
}

func (p *Panel) mcpDrift() (MCPDrift, bool) {
	r, h, ok := p.mcpAt()
	if !ok {
		return MCPDrift{}, false
	}
	var first *MCPDrift
	for i, d := range p.data.mcp.Drift {
		if d.Server == r.Name && d.Harness == h {
			return d, true
		}
		if d.Server == r.Name && first == nil {
			first = &p.data.mcp.Drift[i]
		}
	}
	if first != nil {
		return *first, true
	}
	if len(p.data.mcp.Drift) > 0 {
		return p.data.mcp.Drift[0], true
	}
	return MCPDrift{}, false
}

// mcpDo runs an MCP action in place and reloads the tab.
func (p *Panel) mcpDo(op string, args ...string) tea.Cmd {
	src, ctx := p.src, p.ctx
	if src == nil {
		return nil
	}
	if op == "test" && len(args) > 0 {
		p.notice = "Testing " + args[0] + "…"
	}
	return func() tea.Msg {
		text, err := src.MCPDo(ctx, op, args...)
		return mcpDoneMsg{text, err}
	}
}

type mcpDoneMsg struct {
	text string
	err  error
}

func (p *Panel) mcpKey(k string) tea.Cmd {
	v := p.data.mcp
	switch k {
	case "a":
		return p.run("mcp", "edit")
	case "s":
		if v != nil && v.Pending == 0 {
			p.notice = "Everything is in sync."
			return nil
		}
		return p.mcpDo("sync")
	}
	r, h, ok := p.mcpAt()
	if !ok {
		return nil
	}
	switch k {
	case "left", "h":
		if p.mcpCol > 0 {
			p.mcpCol--
		}
	case "right", "l":
		if p.mcpCol < len(v.Cols)-1 {
			p.mcpCol++
		}
	case "t":
		if !r.Listed {
			p.notice = r.Name + " is no longer in mcp.toml"
			return nil
		}
		return p.mcpDo("test", r.Name)
	case "space", " ":
		switch c := r.Cells[h]; {
		case !r.Listed:
			p.notice = r.Name + " is no longer in mcp.toml; s removes AFK's old entries"
		case c == "conflict":
			p.notice = h + " has its own " + r.Name + "; AFK leaves it alone"
		case c == "unsupported":
			p.notice = r.Notes[h]
		case c == "error":
			p.notice = h + "'s MCP config can't be read"
		case c == "off" || c == "removing":
			return p.mcpDo("enable", r.Name, h)
		default:
			return p.mcpDo("disable", r.Name, h)
		}
	case "enter":
		if !r.Listed {
			p.notice = r.Name + " is no longer in mcp.toml"
			return nil
		}
		return p.mcpListTools(r.Name)
	case "k", "c":
		d, ok := p.mcpDrift()
		if !ok {
			p.notice = "No entry has changed in a CLI."
			return nil
		}
		if k == "k" {
			return p.mcpDo("keep", d.Server, d.Harness)
		}
		return p.mcpDo("restore", d.Server, d.Harness)
	}
	return nil
}

func (p *Panel) mcpLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.mcp
	hint := line{sg(t.Key, "space"), sg(t.Dim, " enable  "), sg(t.Key, "s"), sg(t.Dim, " sync  "), sg(t.Key, "t"), sg(t.Dim, " test  "), sg(t.Key, "↵"), sg(t.Dim, " tools  "), sg(t.Key, "a"), sg(t.Dim, " add  ")}
	tools := 0
	for _, r := range v.Rows {
		tools += max(r.Tools, 0)
	}
	head := line{sg(t.Plain, " "+plural(len(v.Rows), "server", "servers")), sg(t.Dim, " · "+v.Source)}
	if tools > 0 {
		head = append(head, sg(t.Dim, " · "+plural(tools, "tool", "tools")))
	}
	if n := len(v.Drift); n > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Warn, fmt.Sprintf("%d drifted", n)))
	}
	if v.Pending > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Accent, fmt.Sprintf("%d to sync", v.Pending)))
	}
	out := []line{head, nil}
	if len(v.Cols) == 0 {
		return append(out, line{sg(t.Dim, " None of your installed CLIs has an MCP config AFK knows.")}), hint
	}
	if len(v.Rows) == 0 {
		return append(out, line{sg(t.Dim, " No servers yet. Press "), sg(t.Key, "a"), sg(t.Dim, " to add one to "+v.Source+".")}), hint
	}
	nw := 14
	for _, r := range v.Rows {
		nw = max(nw, min(lenCells(r.Name)+2, 24))
	}
	hdr := line{sg(t.Dim, "   "+col("server", nw)+col("via", 14)+col("tools", 6))}
	for _, c := range v.Cols {
		hdr = append(hdr, harnessLogo(t, c), sg(t.Plain, "  "))
	}
	for _, c := range v.Unsupported {
		hdr = append(hdr, harnessLogo(t, c), sg(t.Plain, "  "))
	}
	hdr = append(hdr, sg(t.Dim, "status"))
	out = append(out, hdr)
	sel := min(p.sel[TabMCP], len(v.Rows)-1)
	for i, r := range v.Rows {
		via := r.Via
		if !r.Listed {
			via = "(removed)"
		}
		tl := "–"
		if r.Tools >= 0 {
			tl = fmt.Sprint(r.Tools)
		}
		row := line{sg(t.Plain, "  "+col(r.Name, nw)), sg(t.Dim, col(via, 14)), sg(t.Plain, col(tl, 6))}
		for j, c := range v.Cols {
			cell := r.Cells[c]
			st := t.Dim
			switch cell {
			case "synced":
				st = t.OK
			case "drifted", "conflict", "error":
				st = t.Warn
			case "pending", "removing", "orphan":
				st = t.Accent
			}
			if i == sel && j == p.mcpCol {
				row = append(row, sg(t.Accent.Bold(true), "["), sg(st.Bold(true), mcpMark(cell)), sg(t.Accent.Bold(true), "] "))
				continue
			}
			row = append(row, sg(st, " "+mcpMark(cell)+"  "))
		}
		for range v.Unsupported {
			row = append(row, sg(t.Dim, " –  "))
		}
		stt := t.Dim
		switch r.Status {
		case "up":
			stt = t.OK
		case "down":
			stt = t.Warn
		}
		status := r.Status
		if r.Tested != "" {
			status += " · " + r.Tested
		}
		row = append(row, sg(stt, status))
		out = append(out, p.selRow(row, i, w))
	}
	out = append(out, nil, line{sg(t.Dim, " ✓ in sync  ↻ changed in that CLI  · not enabled  – not supported")})
	if v.Pending > 0 || mcpHas(v, "conflict") || mcpHas(v, "error") {
		out = append(out, line{sg(t.Dim, " + next sync adds it  - next sync removes it  ! yours  ? unreadable")})
	}
	if d, ok := p.mcpDrift(); ok {
		bw := boxW(w)
		out = append(out, nil,
			t.top(d.Server+" changed in "+d.Harness, bw, t.Warn),
			t.boxLine(bw, t.Warn, line{sg(t.Plain, "Edited in "+d.File+" since AFK wrote it.")}),
			t.boxLine(bw, t.Warn, line{sg(t.Key, "k"), sg(t.Dim, " keep "+d.Harness+"'s as its own   "), sg(t.Key, "c"), sg(t.Dim, " restore AFK's entry")}),
			t.bottom(bw, t.Warn))
	} else if r, h, ok := p.mcpAt(); ok {
		text := skillCellText(r.Cells[h])
		switch r.Cells[h] {
		case "unsupported", "error":
			text = r.Notes[h]
		case "conflict":
			text = "an entry of your own with this name; AFK never touches it"
		}
		out = append(out, nil, line{sg(t.Plain, " "), harnessLogo(t, h), sg(t.Bold, " "+r.Name), sg(t.Dim, " in "+h+": "+text)})
	}
	for _, pr := range v.Problems {
		out = append(out, line{sg(t.Warn, " ! "+pr)})
	}
	return out, append(line{sg(t.Key, "←→"), sg(t.Dim, " CLI  ")}, hint...)
}

func mcpHas(v *MCPView, c string) bool {
	for _, r := range v.Rows {
		for _, x := range r.Cells {
			if x == c {
				return true
			}
		}
	}
	return false
}
