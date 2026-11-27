package tui

import (
	"fmt"
	"time"

	tea "charm.land/bubbletea/v2"
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
		return "?"
	case "global":
		return "g"
	case "unsupported":
		return "–"
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
// cell's, else the selected skill's first, else the first.
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
	// Else the first drift anywhere, so an edit is never out of sight.
	if len(p.data.skills.Drift) > 0 {
		return p.data.skills.Drift[0], true
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
		return p.run("skills", "new", "--edit")
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
	hint := line{sg(t.Key, "space"), sg(t.Dim, " enable  "), sg(t.Key, "s"), sg(t.Dim, " sync all  "), sg(t.Key, "n"), sg(t.Dim, " new skill  ")}
	head := line{sg(t.Plain, " "+plural(len(v.Rows), "skill", "skills")), sg(t.Dim, " · source "+v.Source)}
	if n := len(v.Drift); n > 0 {
		head = append(head, sg(t.Dim, " · "), sg(t.Warn, fmt.Sprintf("%d drifted", n)))
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
	hdr := line{sg(t.Dim, "   "+col("skill", nw)+col("source", 10))}
	for _, c := range v.Cols {
		hdr = append(hdr, harnessLogo(t, c), sg(t.Plain, "  "))
	}
	for _, c := range v.Unsupported {
		hdr = append(hdr, harnessLogo(t, c), sg(t.Plain, "  "))
	}
	out = append(out, hdr)
	// Room for the rows: the box and legend take 9 lines, the bar and
	// hints 4.
	room := len(v.Rows)
	if p.height > 0 {
		room = max(3, p.height-len(out)-13)
	}
	sel := min(p.sel[TabSkills], len(v.Rows)-1)
	start := 0
	if sel >= room {
		start = sel - room + 1
	}
	end := min(len(v.Rows), start+room)
	for i := start; i < end; i++ {
		r := v.Rows[i]
		src := "central"
		switch {
		case !r.Central:
			src = "gone"
		case r.Project && r.Scope == "global":
			src = "global"
		case r.Project:
			src = "project"
		}
		row := line{sg(t.Plain, "  "+col(r.Name, nw)), sg(t.Dim, col(src, 10))}
		for j, c := range v.Cols {
			cell := r.Cells[c]
			st := t.Plain
			switch cell {
			case "synced", "native":
				st = t.OK
			case "drifted", "conflict":
				st = t.Warn
			case "pending", "removing", "orphan", "ask":
				st = t.Accent
			default:
				st = t.Dim
			}
			mark := " " + skillMark(cell) + "  "
			if i == sel && j == p.skillCol {
				// Brackets, not a colour: the row already has the
				// selection background.
				row = append(row, sg(t.Accent.Bold(true), "["), sg(st.Bold(true), skillMark(cell)), sg(t.Accent.Bold(true), "] "))
				continue
			}
			row = append(row, sg(st, mark))
		}
		for range v.Unsupported {
			row = append(row, sg(t.Dim, " –  "))
		}
		out = append(out, p.selRow(row, i, w))
	}
	if more := len(v.Rows) - end; more > 0 {
		out = append(out, line{sg(t.Dim, fmt.Sprintf("   …%d more", more))})
	}
	out = append(out, nil, line{sg(t.Dim, " ✓ in sync  ↻ changed in that CLI  · not enabled  – not supported")})
	if v.Pending > 0 || hasCell(v, "conflict") {
		out = append(out, line{sg(t.Dim, " + next sync adds it  - next sync removes it  ! your own skill, left alone")})
	}
	if v.Project != "" {
		out = append(out, line{sg(t.Dim, " project: "+v.Project+"   ? choose where it goes  g every project")})
	}
	if name := p.askScope; name != "" {
		bw := boxW(w)
		out = append(out, nil,
			t.top("Install "+name, bw, t.Accent),
			t.boxLine(bw, t.Accent, line{sg(t.Plain, "From this project's .agents/skills. Where should it go?")}),
			t.boxLine(bw, t.Accent, line{sg(t.Key, "p"), sg(t.Dim, " this project only   "), sg(t.Key, "g"), sg(t.Dim, " every project (copied into central)   "), sg(t.Key, "esc"), sg(t.Dim, " later")}),
			t.bottom(bw, t.Accent))
	} else if d, ok := p.skillDrift(); ok {
		bw := boxW(w)
		ago := "at an unknown time"
		if !d.Modified.IsZero() {
			ago = agoText(p.now().Sub(d.Modified))
		}
		src := "central"
		if d.Project {
			src = "the project's"
		}
		out = append(out, nil,
			t.top(d.Skill+" changed in "+d.Harness, bw, t.Warn),
			t.boxLine(bw, t.Warn, line{sg(t.Plain, fmt.Sprintf("Edited in %s %s. %s differ from %s.", d.Dir, ago, plural(d.Lines, "line", "lines"), src))}),
			t.boxLine(bw, t.Warn, line{sg(t.Key, "d"), sg(t.Dim, " diff   "), sg(t.Key, "k"), sg(t.Dim, " keep "+d.Harness+"'s and update "+src+"   "), sg(t.Key, "c"), sg(t.Dim, " restore "+src)}),
			t.bottom(bw, t.Warn))
	} else if r, h, ok := p.skillAt(); ok {
		out = append(out, nil, line{sg(t.Plain, " "), harnessLogo(t, h), sg(t.Bold, " "+r.Name), sg(t.Dim, " in "+h+": "+skillCellText(r.Cells[h]))})
	}
	for _, pr := range v.Problems {
		out = append(out, line{sg(t.Warn, " ! "+pr)})
	}
	return out, append(line{sg(t.Key, "←→"), sg(t.Dim, " CLI  ")}, hint...)
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
