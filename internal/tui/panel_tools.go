package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
)

// MCPTool is one tool a server offers.
type MCPTool struct{ Name, Description string }

// toolsView is a server's tools, open over the MCP tab (↵ on a row).
type toolsView struct {
	server string
	tools  []MCPTool
	sel    int
}

type mcpToolsMsg struct {
	panel  int
	gen    int // only the latest listing opens
	server string
	tools  []MCPTool
	err    error
}

// mcpListTools asks the server for its tools.
func (p *Panel) mcpListTools(server string) tea.Cmd {
	src, ctx, id := p.src, p.ctx, p.id
	if src == nil {
		return nil
	}
	p.toolsGen++
	gen := p.toolsGen
	p.notice = "Listing " + server + "'s tools…"
	return func() tea.Msg {
		tools, err := src.MCPTools(ctx, server)
		return mcpToolsMsg{panel: id, gen: gen, server: server, tools: tools, err: err}
	}
}

func (p *Panel) toolsKey(k string) tea.Cmd {
	v := p.tools
	switch k {
	case "esc", "enter", "backspace", "left", "h":
		p.tools = nil
	case "up", "k":
		if v.sel > 0 {
			v.sel--
		}
	case "down", "j":
		if v.sel < len(v.tools)-1 {
			v.sel++
		}
	case "pgup":
		v.sel = max(v.sel-10, 0)
	case "pgdown", "space":
		v.sel = min(v.sel+10, max(len(v.tools)-1, 0))
	case "home", "g":
		v.sel = 0
	case "end", "G":
		v.sel = max(len(v.tools)-1, 0)
	case "q", "ctrl+c":
		p.quit = true
	case "r":
		p.tools = nil
		return p.load(p.tab)
	}
	return nil
}

func (p *Panel) toolsLines(w int) ([]line, line) {
	t := p.theme
	v := p.tools
	hint := line{sg(t.Key, "↑↓"), sg(t.Dim, " scroll  "), sg(t.Key, "esc"), sg(t.Dim, " back to servers  ")}
	out := []line{{sg(t.Bold, " "+v.server), sg(t.Dim, " · "+plural(len(v.tools), "tool", "tools"))}, nil}
	if len(v.tools) == 0 {
		return append(out, line{sg(t.Dim, " This server offers no tools.")}), hint
	}
	nw := 12
	for _, x := range v.tools {
		nw = max(nw, min(lenCells(x.Name)+2, 32))
	}
	for i, x := range v.tools {
		desc := strings.Join(strings.Fields(x.Description), " ") // one line
		mark := sg(t.Plain, " ")                                 // scrollTo finds the selected row by its ▌
		name := sg(t.Plain, col(x.Name, nw))
		if i == v.sel {
			mark, name = sg(t.Accent, "▌"), sg(t.Bold, col(x.Name, nw))
		}
		out = append(out, line{mark, sg(t.Plain, " "), name, sg(t.Dim, desc)})
	}
	return out, hint
}
