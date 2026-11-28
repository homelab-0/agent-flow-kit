package tui

import (
	"fmt"
	"strings"

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
	// Project is the repository's .mcp.json ("" when it has none); its
	// servers are the rows with Project set.
	Project   string
	Undecided int // project servers waiting for a scope
	// Found are servers in the CLIs' own configs that mcp.toml doesn't
	// list: ones added to a CLI by hand, which i imports.
	Found []MCPFound
}

// MCPFound is a server found in a CLI's own MCP config.
type MCPFound struct {
	Name, Where string
	In          []string
	Why         string   // why it can't be imported ("" when it can)
	Left        []string // what importing doesn't copy (values in the file)
	Differs     bool     // the CLIs' entries aren't the same
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
	// Project is a server from the repository's .mcp.json; Scope is
	// "project", "global" or "" (not chosen yet).
	Project bool
	Scope   string
	// Where is its URL or command; Token the variable holding its bearer
	// token and Env the variables it is passed (names only); TestError
	// the last test's error; Files each CLI's MCP config file.
	Where, Token, TestError string
	Env                     []string
	Files                   map[string]string
}

// MCPDrift is an entry edited in a CLI since AFK wrote it.
type MCPDrift struct {
	Server, Harness, File string
	Project               bool
}

// mcpOp is op for the project's servers when project is set.
func mcpOp(project bool, op string) string {
	if project {
		return "project:" + op
	}
	return op
}

// mcpSource is the file a row's server comes from.
func mcpSource(project bool) string {
	if project {
		return ".mcp.json"
	}
	return "mcp.toml"
}

func mcpMark(c string) string {
	switch c {
	case "unsupported":
		return "–"
	case "error":
		return "✗" // ? asks where a project server goes
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
		if d.Server != r.Name || d.Project != r.Project {
			continue
		}
		if d.Harness == h {
			return d, true
		}
		if first == nil {
			first = &p.data.mcp.Drift[i]
		}
	}
	if first != nil {
		return *first, true
	}
	return MCPDrift{}, false
}

// mcpDo runs an MCP action in place and reloads the tab.
func (p *Panel) mcpDo(op string, args ...string) tea.Cmd {
	src, ctx := p.src, p.ctx
	if src == nil {
		return nil
	}
	if strings.HasSuffix(op, "test") && len(args) > 0 {
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
	if name := p.askScope; name != "" {
		p.askScope = ""
		switch k {
		case "p":
			return p.mcpDo("project:scope", name, "project")
		case "g":
			return p.mcpDo("project:scope", name, "global")
		}
		return nil // any other key: decide later
	}
	switch k {
	case "a":
		p.ask = &panelAsk{tab: TabMCP, label: "new server",
			hint: "A name, then where it is. An address: github https://api.example/mcp env:GITHUB_MCP_TOKEN (the last part names the variable holding its token; leave it out for none). A command: playwright npx @playwright/mcp@latest. Through a gateway: tools via:work.",
			done: func(text string) tea.Cmd { return p.mcpDo("add", text) }}
		return nil
	case "e":
		return p.run("mcp", "edit")
	case "i":
		if v == nil || importable(v) == 0 {
			p.notice = "Nothing to import: every server in your CLIs' own configs is in mcp.toml, or can't be copied."
			return nil
		}
		return p.mcpDo("import")
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
			p.notice = r.Name + " is no longer in " + mcpSource(r.Project)
			return nil
		}
		return p.mcpDo(mcpOp(r.Project, "test"), r.Name)
	case "space", " ":
		switch c := r.Cells[h]; {
		case c == "native":
			p.notice = h + " reads .mcp.json itself, so it always has " + r.Name + " in this project"
		case r.Project && r.Listed && (r.Scope == "" || c == "ask" || c == "global"):
			p.askScope = r.Name
		case !r.Listed && r.Project:
			p.notice = r.Name + " is no longer in .mcp.json; s removes AFK's old copies"
		case !r.Listed:
			p.notice = r.Name + " is no longer in mcp.toml; s removes AFK's old entries"
		case c == "conflict":
			p.notice = h + " has its own " + r.Name + "; AFK leaves it alone"
		case c == "unsupported":
			p.notice = r.Notes[h]
		case c == "error":
			p.notice = h + "'s MCP config can't be read"
		case c == "off" || c == "removing":
			return p.mcpDo(mcpOp(r.Project, "enable"), r.Name, h)
		default:
			return p.mcpDo(mcpOp(r.Project, "disable"), r.Name, h)
		}
	case "enter":
		if !r.Listed {
			p.notice = r.Name + " is no longer in " + mcpSource(r.Project)
			return nil
		}
		return p.mcpListTools(mcpOp(r.Project, r.Name))
	case "k", "c":
		d, ok := p.mcpDrift()
		if !ok {
			p.notice = "No entry has changed in a CLI."
			return nil
		}
		if k == "k" {
			return p.mcpDo(mcpOp(d.Project, "keep"), d.Server, d.Harness)
		}
		return p.mcpDo(mcpOp(d.Project, "restore"), d.Server, d.Harness)
	}
	return nil
}

func (p *Panel) mcpLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.mcp
	hint := line{sg(t.Key, "space"), sg(t.Dim, " on/off  "), sg(t.Key, "s"), sg(t.Dim, " sync  "), sg(t.Key, "t"), sg(t.Dim, " test  "), sg(t.Key, "↵"), sg(t.Dim, " tools  "), sg(t.Key, "a"), sg(t.Dim, " add  ")}
	if importable(v) > 0 {
		hint = append(hint, sg(t.Key, "i"), sg(t.Dim, " import  "))
	}
	hint = append(hint, sg(t.Key, "e"), sg(t.Dim, " edit mcp.toml  "))
	tools := 0
	for _, r := range v.Rows {
		tools += max(r.Tools, 0)
	}
	head := line{sg(t.Plain, " "+plural(len(v.Rows), "server", "servers")), sg(t.Dim, " · "+v.Source)}
	if tools > 0 {
		head = append(head, sg(t.Dim, " · "+plural(tools, "tool", "tools")))
	}
	if n := len(v.Drift); n > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Warn, fmt.Sprintf("%d edited", n)))
	}
	if v.Pending > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Accent, fmt.Sprintf("%d to sync", v.Pending)))
	}
	if v.Undecided > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Accent, fmt.Sprintf("%d to choose", v.Undecided)))
	}
	out := []line{head}
	if len(v.Cols) == 0 {
		return append(out, nil, line{sg(t.Dim, " None of your installed CLIs has an MCP config AFK knows.")}), hint
	}
	asking := p.askScope != ""
	if !asking {
		out = append(out, p.mcpFoundBox(w)...)
	}
	out = append(out, nil)
	if len(v.Rows) == 0 {
		empty := line{sg(t.Dim, " No servers in "+v.Source+" yet. "), sg(t.Key, "a"), sg(t.Dim, " adds one")}
		if importable(v) > 0 {
			empty = append(empty, sg(t.Dim, ", "), sg(t.Key, "i"), sg(t.Dim, " imports the ones above"))
		}
		return append(out, empty), hint
	}
	nw := 14
	for _, r := range v.Rows {
		nw = max(nw, min(lenCells(r.Name)+2, 24))
	}
	hdr := line{sg(t.Dim, "   "+col("server", nw)+col("how", 18)+col("tools", 6)+col("health", 13))}
	codes := line{sg(t.Plain, strings.Repeat(" ", 3+nw+18+6+13))}
	captions := false
	for _, c := range append(append([]string{}, v.Cols...), v.Unsupported...) {
		hdr = append(hdr, harnessLogo(t, c), sg(t.Plain, "  "))
		code := logoCaption(t, c)
		captions = captions || code != ""
		codes = append(codes, sg(t.Dim, col(code, 4)))
	}
	out = append(out, hdr)
	if captions {
		out = append(out, codes)
	}
	sel := min(p.sel[TabMCP], len(v.Rows)-1)
	for i, r := range v.Rows {
		if asking && i != sel {
			continue // the question box stays on screen: only its row shows
		}
		tl := "–"
		if r.Tools >= 0 {
			tl = fmt.Sprint(r.Tools)
		}
		nst := t.Plain
		if i == sel {
			nst = t.Bold
		}
		hstate, htext := mcpHealth(r)
		row := line{sg(nst, "  "+col(r.Name, nw)), sg(t.Dim, col(mcpHow(r), 18)), sg(t.Plain, col(tl, 6)), t.dot(hstate), sg(t.Dim, " "+col(htext, 11))}
		for j, c := range v.Cols {
			cell := r.Cells[c]
			st := skillStyle(t, cell)
			if cell == "error" {
				st = t.Warn
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
		out = append(out, p.selRow(row, i, w))
	}
	if !asking {
		legend := line{sg(t.Plain, " "), sg(t.OK, "✓"), sg(t.Dim, " written  "), sg(t.Warn, "↻"), sg(t.Dim, " edited there  "), sg(t.Dim, "○ off  – can't take it")}
		if mcpHas(v, "ask") {
			legend = append(line{sg(t.Plain, " "), sg(t.Accent, "◆"), sg(t.Dim, " needs a choice ")}, legend...)
		}
		out = append(out, nil, legend)
		if v.Pending > 0 || mcpHas(v, "conflict") || mcpHas(v, "error") {
			out = append(out, line{sg(t.Plain, " "), sg(t.Accent, "+"), sg(t.Dim, " next sync adds it  "), sg(t.Accent, "-"), sg(t.Dim, " next sync removes it  "), sg(t.Warn, "!"), sg(t.Dim, " yours, left alone  "), sg(t.Warn, "✗"), sg(t.Dim, " unreadable")})
		}
		if v.Project != "" {
			out = append(out, line{sg(t.Dim, " project servers from "+v.Project)})
		}
	}
	out = append(out, p.mcpBox(w)...)
	for _, pr := range v.Problems {
		out = append(out, line{sg(t.Warn, " ! "+pr)})
	}
	return out, append(line{sg(t.Key, "←→"), sg(t.Dim, " CLI  ")}, hint...)
}

// importable is how many found servers i can import.
func importable(v *MCPView) int {
	n := 0
	for _, f := range v.Found {
		if f.Why == "" {
			n++
		}
	}
	return n
}

// mcpFoundBox offers the servers found in the CLIs' own configs.
func (p *Panel) mcpFoundBox(w int) []line {
	t := p.theme
	v := p.data.mcp
	if len(v.Found) == 0 {
		return nil
	}
	bw := boxW(w)
	n := importable(v)
	title := fmt.Sprintf("Found in your CLIs' own configs: %s", plural(len(v.Found), "server", "servers"))
	lw := 0
	for _, f := range v.Found {
		lw = max(lw, 3*len(f.In))
	}
	var body []line
	for i, f := range v.Found {
		if i == 4 {
			body = append(body, line{sg(t.Dim, fmt.Sprintf("…%d more (afk mcp import lists them all)", len(v.Found)-4))})
			break
		}
		l := line{sg(t.Bold, col(f.Name, 16))}
		for _, h := range f.In {
			l = append(l, harnessLogo(t, h), sg(t.Plain, " "))
		}
		l = l.pad(16+lw, t.Plain)
		if f.Why != "" {
			l = append(l, sg(t.Warn, "can't import: "+f.Why))
		} else {
			l = append(l, sg(t.Dim, f.Where))
		}
		body = append(body, l)
		if f.Why == "" && len(f.Left) > 0 {
			body = append(body, line{sg(t.Plain, strings.Repeat(" ", 16+lw)), sg(t.Warn, "not copied: "+strings.Join(f.Left, ", "))})
		}
	}
	if n > 0 {
		what := "all " + fmt.Sprint(n)
		if n == 1 {
			what = "it"
		}
		body = append(body, nil)
		for i, l := range wrap("adds "+what+" to mcp.toml. Your CLIs' files don't change, and values written in them (tokens, env) are never copied.", bw-6) {
			if i == 0 {
				body = append(body, line{sg(t.Key, "i"), sg(t.Dim, " "+l)})
			} else {
				body = append(body, line{sg(t.Dim, l)})
			}
		}
	}
	out := []line{nil, t.top(title, bw, t.Accent)}
	for _, l := range body {
		out = append(out, t.boxLine(bw, t.Accent, l))
	}
	return append(out, t.bottom(bw, t.Accent))
}

// mcpHow is how a server is reached, short: http, stdio and its program,
// or the gateway it goes through.
func mcpHow(r MCPRow) string {
	switch {
	case !r.Listed:
		return "removed"
	case r.Project && r.Scope == "global":
		return "project → all"
	case r.Via == "http":
		if r.Token != "" {
			return "http · $" + r.Token
		}
		return "http"
	case r.Via == "stdio" || r.Via == "":
		prog := strings.Fields(r.Where)
		if len(prog) > 0 {
			return "stdio · " + prog[0]
		}
		return "stdio"
	}
	return "gateway " + r.Via
}

// mcpHealth is a server's last test as a dot state and text.
func mcpHealth(r MCPRow) (string, string) {
	switch r.Status {
	case "up":
		return "ok", "up " + r.Tested
	case "down":
		return "bad", "failed " + r.Tested
	}
	return "", "untested"
}

// mcpBox is the selected server in full, or the question or edit it
// waits on.
func (p *Panel) mcpBox(w int) []line {
	t := p.theme
	r, h, ok := p.mcpAt()
	if !ok {
		return nil
	}
	bw := boxW(w)
	border, title := t.Border, r.Name
	var body []line
	switch d, drifted := p.mcpDrift(); {
	case p.askScope == r.Name:
		border, title = t.Accent, "Add "+r.Name
		body = append(body, line{sg(t.Plain, "From this project's .mcp.json. Where should it go?")},
			line{sg(t.Key, "p"), sg(t.Dim, " this project only   "), sg(t.Key, "g"), sg(t.Dim, " every project (added to mcp.toml)   "), sg(t.Key, "esc"), sg(t.Dim, " later")})
	case drifted:
		border, title = t.Warn, d.Server+" changed in "+d.Harness
		body = append(body, line{sg(t.Plain, "Edited in "+d.File+" since AFK wrote it.")},
			line{sg(t.Key, "k"), sg(t.Dim, " keep "+d.Harness+"'s as its own   "), sg(t.Key, "c"), sg(t.Dim, " restore AFK's entry")})
	default:
		if r.Where != "" {
			body = append(body, t.field(map[bool]string{true: "url", false: "command"}[r.Via == "http"], sg(t.Plain, r.Where)))
		}
		if r.Token != "" {
			body = append(body, t.field("token", sg(t.Plain, "$"+r.Token), sg(t.Dim, " (a variable name; AFK never reads it)")))
		}
		if len(r.Env) > 0 {
			body = append(body, t.field("env", sg(t.Plain, strings.Join(r.Env, ", ")), sg(t.Dim, " (names only)")))
		}
		st, txt := mcpHealth(r)
		tested := line{t.dot(st), sg(t.Plain, " "+txt)}
		switch {
		case r.Status == "up":
			tested = append(tested, sg(t.Dim, " · "+plural(r.Tools, "tool", "tools")))
		case r.Status == "down":
			if r.TestError != "" {
				tested = append(tested, sg(t.Warn, " · "+r.TestError))
			}
		default:
			tested = append(tested, sg(t.Dim, " · "), sg(t.Key, "t"), sg(t.Dim, " tests it"))
		}
		body = append(body, t.field("tested", tested...), nil)
		text := skillCellText(r.Cells[h])
		switch r.Cells[h] {
		case "unsupported", "error":
			text = r.Notes[h]
		case "conflict":
			text = "an entry of your own with this name; AFK never touches it"
		case "native":
			text = "reads .mcp.json itself"
		case "ask":
			text = "a project server: space chooses this project or every project"
		case "global":
			text = "added for every project from mcp.toml"
		case "synced":
			text = "written by AFK, in sync"
		}
		cli := line{harnessLogo(t, h), sg(t.Bold, " "+h+"  "), sg(skillStyle(t, r.Cells[h]), mcpMark(r.Cells[h])), sg(t.Dim, " "+text)}
		body = append(body, cli)
		if f := r.Files[h]; f != "" {
			body = append(body, line{sg(t.Dim, "   "+f)})
		}
	}
	out := []line{nil, t.top(title, bw, border)}
	for _, l := range body {
		out = append(out, t.boxLine(bw, border, l))
	}
	return append(out, t.bottom(bw, border))
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
