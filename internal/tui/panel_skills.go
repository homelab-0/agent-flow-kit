package tui

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// SkillsView is the Skills tab: every central skill in every CLI.
type SkillsView struct {
	Source string   // the central folder, as people read it (~/.config/afk/skills)
	Cols   []string // CLIs AFK syncs skills into
	// Unsupported are installed CLIs with no skills folder AFK knows.
	Unsupported []string
	Rows        []SkillRow
	Drift       []SkillDrift
	Pending     int // changes the next sync makes
	Problems    []string
	// Project is the repository's .agents/skills ("" when it has none);
	// its skills are the rows with Project set.
	Project   string
	Undecided int // project skills waiting for a scope
}

// SkillRow is one skill. Cells holds the skills package's cell names by
// CLI: synced, pending, drifted, off, conflict, removing, orphan, unmanaged.
type SkillRow struct {
	Name    string
	Central bool
	Cells   map[string]string
	// Project is a skill from the repository's .agents/skills; Scope is
	// "project", "global" or "" (not chosen yet).
	Project bool
	Scope   string
	// Desc is the description in its SKILL.md; Dir is its folder (central
	// or the project's), with how many files it holds and when one last
	// changed. All empty when the skill is no longer central.
	Desc, Dir string
	Files     int
	Modified  time.Time
}

// SkillDrift is a CLI's copy edited since AFK synced it.
type SkillDrift struct {
	Project             bool
	Skill, Harness, Dir string
	Modified            time.Time
	Lines               int
}

// skillsDoneMsg is what an in-place skills action said.
type skillsDoneMsg struct {
	text string
	err  error
}

func skillMark(c string) string {
	switch c {
	case "synced":
		return "✓"
	case "drifted":
		return "↻"
	case "pending":
		return "+"
	case "removing", "orphan":
		return "-"
	case "conflict":
		return "!"
	case "native":
		return "✓"
	case "ask":
		return "◆"
	case "global":
		return "✓"
	case "unsupported":
		return "–"
	case "off":
		return "○"
	}
	return "·"
}

// skillOp is op for a row: "project:" in front for a project skill.
func skillOp(project bool, op string) string {
	if project {
		return "project:" + op
	}
	return op
}

// skillDo runs a skills action in place (no terminal hand-over) and
// reloads the tab with what it said.
func (p *Panel) skillDo(op string, args ...string) tea.Cmd {
	src, ctx := p.src, p.ctx
	if src == nil {
		return nil
	}
	return func() tea.Msg {
		text, err := src.SkillsDo(ctx, op, args...)
		return skillsDoneMsg{text, err}
	}
}

// skillAt is the selected skill and CLI.
func (p *Panel) skillAt() (SkillRow, string, bool) {
	v := p.data.skills
	if v == nil || len(v.Rows) == 0 || len(v.Cols) == 0 {
		return SkillRow{}, "", false
	}
	r := v.Rows[min(p.sel[TabSkills], len(v.Rows)-1)]
	return r, v.Cols[min(p.skillCol, len(v.Cols)-1)], true
}

// skillDrift is the drift the box (and d, k, c) is about: the selected
// skill's copy in the selected CLI, else its first edited copy.
func (p *Panel) skillDrift() (SkillDrift, bool) {
	r, h, ok := p.skillAt()
	if !ok {
		return SkillDrift{}, false
	}
	var first *SkillDrift
	for i, d := range p.data.skills.Drift {
		if d.Skill != r.Name {
			continue
		}
		if d.Harness == h {
			return d, true
		}
		if first == nil {
			first = &p.data.skills.Drift[i]
		}
	}
	if first != nil {
		return *first, true
	}
	return SkillDrift{}, false
}

func (p *Panel) skillsKey(k string) tea.Cmd {
	v := p.data.skills
	if name := p.askScope; name != "" {
		p.askScope = ""
		switch k {
		case "p":
			return p.skillDo("project:scope", name, "project")
		case "g":
			return p.skillDo("project:scope", name, "global")
		}
		return nil // any other key: decide later
	}
	switch k {
	case "n":
		p.ask = &panelAsk{tab: TabSkills, label: "new skill",
			hint: "A name (lowercase letters, digits, . _ -), then when to use it. For example: pr-triage Use when asked to review or sort pull requests.",
			done: func(text string) tea.Cmd {
				name, desc, _ := strings.Cut(text, " ")
				return p.skillDo("new", name, strings.TrimSpace(desc))
			}}
		return nil
	case "e":
		// The skill's own text is written in an editor.
		if v != nil && p.sel[TabSkills] < len(v.Rows) && len(v.Rows) > 0 {
			return p.run("skills", "edit", v.Rows[p.sel[TabSkills]].Name)
		}
		return nil
	case "s":
		if v != nil && v.Pending == 0 {
			p.notice = "Everything is in sync."
			return nil
		}
		return p.skillDo("sync")
	}
	r, h, ok := p.skillAt()
	if !ok {
		return nil
	}
	switch k {
	case "left", "h":
		if p.skillCol > 0 {
			p.skillCol--
		}
	case "right", "l":
		if p.skillCol < len(v.Cols)-1 {
			p.skillCol++
		}
	case "space", " ":
		switch c := r.Cells[h]; {
		case r.Project && r.Central && (r.Scope == "" || c == "ask" || c == "global"):
			p.askScope = r.Name
		case c == "native":
			p.notice = h + " reads .agents/skills itself, so it always has " + r.Name + " in this project"
		case c == "unsupported":
			p.notice = h + " has no project skills folder AFK knows"
		case !r.Central && r.Project:
			p.notice = r.Name + " is no longer in .agents/skills; s removes AFK's old copies"
		case !r.Central:
			p.notice = r.Name + " is no longer central; s removes AFK's old copies"
		case c == "conflict":
			p.notice = h + " has its own " + r.Name + "; AFK leaves it alone"
		case c == "off" || c == "removing":
			return p.skillDo(skillOp(r.Project, "enable"), r.Name, h)
		default:
			return p.skillDo(skillOp(r.Project, "disable"), r.Name, h)
		}
	case "d", "k", "c":
		d, ok := p.skillDrift()
		if !ok {
			p.notice = "No skill has changed in a CLI."
			return nil
		}
		switch k {
		case "d":
			if d.Project {
				return p.run("skills", "diff", d.Skill, d.Harness, "--wait", "--project")
			}
			return p.run("skills", "diff", d.Skill, d.Harness, "--wait")
		case "k":
			return p.skillDo(skillOp(d.Project, "keep"), d.Skill, d.Harness)
		default:
			return p.skillDo(skillOp(d.Project, "restore"), d.Skill, d.Harness)
		}
	}
	return nil
}

func (p *Panel) skillsLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.skills
	hint := line{sg(t.Key, "space"), sg(t.Dim, " on/off  "), sg(t.Key, "s"), sg(t.Dim, " sync all  "), sg(t.Key, "n"), sg(t.Dim, " new skill  "), sg(t.Key, "e"), sg(t.Dim, " edit its text  ")}
	head := line{sg(t.Plain, " "+plural(len(v.Rows), "skill", "skills")), sg(t.Dim, " · central "+v.Source)}
	if n := len(v.Drift); n > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Warn, fmt.Sprintf("%d edited", n)))
	}
	if v.Pending > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Accent, fmt.Sprintf("%d to sync", v.Pending)))
	}
	if v.Undecided > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Accent, fmt.Sprintf("%d to choose", v.Undecided)))
	}
	out := []line{head, nil}
	if len(v.Cols) == 0 {
		return append(out, line{sg(t.Dim, " None of your installed CLIs has a skills folder AFK knows.")}), hint
	}
	if len(v.Rows) == 0 {
		return append(out, line{sg(t.Dim, " No skills yet. Press "), sg(t.Key, "n"), sg(t.Dim, " to start one in "+v.Source+".")}), hint
	}
	nw := 20
	for _, r := range v.Rows {
		nw = max(nw, min(lenCells(r.Name)+2, 32))
	}
	// Each CLI is a 4-cell column under its logo; the mark sits under
	// the logo's second cell.
	hdr := line{sg(t.Dim, "   "+col("skill", nw)+col("scope", 11))}
	codes := line{sg(t.Plain, strings.Repeat(" ", 3+nw+11))}
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
	box := p.skillBox(w)
	// Room for the rows: the legend, the box and the bar with its hints.
	room := len(v.Rows)
	if p.height > 0 {
		room = max(3, p.height-len(out)-len(box)-len(v.Problems)-8)
	}
	sel := min(p.sel[TabSkills], len(v.Rows)-1)
	start := 0
	if sel >= room {
		start = sel - room + 1
	}
	end := min(len(v.Rows), start+room)
	for i := start; i < end; i++ {
		r := v.Rows[i]
		scope, sst := skillScope(r)
		nst := t.Plain
		if i == sel {
			nst = t.Bold
		}
		row := line{sg(nst, "  "+col(r.Name, nw)), sg(map[string]lipgloss.Style{"accent": t.Accent, "warn": t.Warn}[sst], col(scope, 11))}
		if sst == "" {
			row[1] = sg(t.Dim, col(scope, 11))
		}
		for j, c := range v.Cols {
			cell := r.Cells[c]
			st := skillStyle(t, cell)
			if i == sel && j == p.skillCol {
				// Brackets, not a colour: the row already has the
				// selection background.
				row = append(row, sg(t.Accent.Bold(true), "["), sg(st.Bold(true), skillMark(cell)), sg(t.Accent.Bold(true), "] "))
				continue
			}
			row = append(row, sg(st, " "+skillMark(cell)+"  "))
		}
		for range v.Unsupported {
			row = append(row, sg(t.Dim, " –  "))
		}
		out = append(out, p.selRow(row, i, w))
	}
	if more := len(v.Rows) - end; more > 0 {
		out = append(out, line{sg(t.Dim, fmt.Sprintf("   …%d more", more))})
	}
	legend := line{sg(t.Plain, " "), sg(t.OK, "✓"), sg(t.Dim, " installed  "), sg(t.Warn, "↻"), sg(t.Dim, " edited there  "), sg(t.Dim, "○ off  – no skills folder")}
	if hasCell(v, "ask") {
		legend = append(line{sg(t.Plain, " "), sg(t.Accent, "◆"), sg(t.Dim, " needs a choice ")}, legend...)
	}
	out = append(out, nil, legend)
	if v.Pending > 0 || hasCell(v, "conflict") {
		out = append(out, line{sg(t.Plain, " "), sg(t.Accent, "+"), sg(t.Dim, " next sync adds it  "), sg(t.Accent, "-"), sg(t.Dim, " next sync removes it  "), sg(t.Warn, "!"), sg(t.Dim, " your own skill, left alone")})
	}
	if v.Project != "" {
		out = append(out, line{sg(t.Dim, " project skills from "+v.Project)})
	}
	out = append(out, box...)
	for _, pr := range v.Problems {
		out = append(out, line{sg(t.Warn, " ! "+pr)})
	}
	return out, append(line{sg(t.Key, "←→"), sg(t.Dim, " CLI  ")}, hint...)
}

// skillScope is where a skill applies, as the scope column shows it, and
// how to colour it ("accent", "warn" or "" for dim).
func skillScope(r SkillRow) (string, string) {
	switch {
	case !r.Central:
		return "removed", "warn"
	case r.Project && r.Scope == "global":
		return "everywhere", ""
	case r.Project && r.Scope == "project":
		return "project", "accent"
	case r.Project:
		return "choose", "accent"
	}
	return "everywhere", ""
}

func skillStyle(t Theme, cell string) lipgloss.Style {
	switch cell {
	case "synced", "native", "global":
		return t.OK
	case "drifted", "conflict":
		return t.Warn
	case "pending", "removing", "orphan", "ask":
		return t.Accent
	}
	return t.Dim
}

// skillBox is the selected skill in full: what it is, where it lives,
// and the selected CLI's copy with what can be done about it.
func (p *Panel) skillBox(w int) []line {
	t := p.theme
	r, h, ok := p.skillAt()
	if !ok {
		return nil
	}
	bw := boxW(w)
	border := t.Border
	var body []line
	if r.Desc != "" {
		for _, l := range wrap(r.Desc, bw-4) {
			body = append(body, line{sg(t.Plain, l)})
		}
	}
	if r.Dir != "" {
		from := line{sg(t.Dim, "from  "), sg(t.Plain, r.Dir)}
		if r.Files > 0 {
			from = append(from, sg(t.Dim, " · "+plural(r.Files, "file", "files")))
		}
		if !r.Modified.IsZero() {
			from = append(from, sg(t.Dim, " · edited "+agoText(p.now().Sub(r.Modified))))
		}
		body = append(body, from)
	} else if !r.Central {
		body = append(body, line{sg(t.Warn, "No longer in central; the next sync removes AFK's copies.")})
	}
	if len(body) > 0 {
		body = append(body, nil)
	}
	title := r.Name
	cli := line{harnessLogo(t, h), sg(t.Bold, " "+h+"  "), sg(skillStyle(t, r.Cells[h]), skillMark(r.Cells[h])), sg(t.Dim, " "+skillCellText(r.Cells[h]))}
	d, drifted := p.skillDrift()
	switch {
	case p.askScope == r.Name:
		border, title = t.Accent, "Install "+r.Name
		body = append(body,
			line{harnessLogo(t, h), sg(t.Plain, " Where should "+r.Name+" go?")},
			line{sg(t.Plain, "   "), sg(t.Key, "p"), sg(t.Dim, " this project only   "), sg(t.Key, "g"), sg(t.Dim, " every project (copied into central)   "), sg(t.Key, "esc"), sg(t.Dim, " later")})
	case drifted:
		border, title = t.Warn, r.Name+" changed in "+d.Harness
		cli = line{harnessLogo(t, d.Harness), sg(t.Bold, " "+d.Harness+"  "), sg(t.Warn, "↻"), sg(t.Dim, " "+skillCellText("drifted"))}
		ago := "at an unknown time"
		if !d.Modified.IsZero() {
			ago = agoText(p.now().Sub(d.Modified))
		}
		src := "central"
		if d.Project {
			src = "the project's"
		}
		body = append(body, cli,
			line{sg(t.Plain, fmt.Sprintf("Edited in %s %s. %s differ from %s.", d.Dir, ago, plural(d.Lines, "line", "lines"), src))},
			line{sg(t.Key, "d"), sg(t.Dim, " diff   "), sg(t.Key, "k"), sg(t.Dim, " keep "+d.Harness+"'s and update "+src+"   "), sg(t.Key, "c"), sg(t.Dim, " restore "+src)})
	default:
		body = append(body, cli)
		if r.Cells[h] == "ask" {
			body = append(body, line{sg(t.Dim, "   "), sg(t.Key, "space"), sg(t.Dim, " choose this project or every project")})
		}
	}
	out := []line{nil, t.top(title, bw, border)}
	for _, l := range body {
		out = append(out, t.boxLine(bw, border, l))
	}
	return append(out, t.bottom(bw, border))
}

func hasCell(v *SkillsView, c string) bool {
	for _, r := range v.Rows {
		for _, x := range r.Cells {
			if x == c {
				return true
			}
		}
	}
	return false
}

func skillCellText(c string) string {
	switch c {
	case "synced":
		return "in sync with central"
	case "pending":
		return "the next sync copies it in"
	case "off":
		return "turned off (space turns it on)"
	case "removing":
		return "turned off; the next sync removes AFK's copy"
	case "orphan":
		return "no longer central; the next sync removes AFK's copy"
	case "conflict":
		return "a skill of your own with this name; AFK never touches it"
	case "drifted":
		return "changed in that CLI"
	case "native":
		return "reads .agents/skills itself"
	case "ask":
		return "a project skill: space chooses this project or every project"
	case "global":
		return "installed for every project from central"
	case "unsupported":
		return "no project skills folder AFK knows"
	}
	return "not there"
}

// agoText is a duration as "2 hours ago".
func agoText(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return plural(int(d/time.Minute), "minute", "minutes") + " ago"
	case d < 48*time.Hour:
		return plural(int(d/time.Hour), "hour", "hours") + " ago"
	}
	return plural(int(d/(24*time.Hour)), "day", "days") + " ago"
}
