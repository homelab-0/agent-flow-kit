package tui

import (
	"strings"
	"unicode/utf8"
)

// The / filter narrows a tab's rows to those whose names contain what is
// typed, ignoring case. Each tab keeps its own filter. The loaded data
// stays whole in p.raw; p.data holds the rows that match.

// filterKey handles a key while the filter is being typed. It reports
// whether it used the key.
func (p *Panel) filterKey(k string) bool {
	if !p.typing {
		return false
	}
	f := p.filter[p.tab]
	switch k {
	case "enter":
		p.typing = false
		return true
	case "esc":
		p.typing = false
		f = ""
	case "backspace":
		if f != "" {
			_, n := utf8.DecodeLastRuneInString(f)
			f = f[:len(f)-n]
		}
	case "space":
		f += " "
	case "ctrl+u":
		f = ""
	default:
		if utf8.RuneCountInString(k) != 1 {
			return true // other keys do nothing while typing
		}
		f += k
	}
	p.setFilter(f)
	return true
}

// filterable is whether a tab has rows to filter.
func filterable(t Tab) bool {
	switch t {
	case TabHarnesses, TabBench, TabSkills, TabMCP, TabRuns, TabConfig:
		return true
	}
	return false
}

func (p *Panel) setFilter(f string) {
	if f == p.filter[p.tab] {
		return
	}
	p.filter[p.tab] = f
	p.sel[p.tab] = 0
	p.refilter(p.tab)
}

// refilter rebuilds a tab's shown rows from the loaded ones.
func (p *Panel) refilter(t Tab) {
	f := strings.ToLower(strings.TrimSpace(p.filter[t]))
	match := func(fields ...string) bool {
		if f == "" {
			return true
		}
		for _, s := range fields {
			if strings.Contains(strings.ToLower(s), f) {
				return true
			}
		}
		return false
	}
	switch t {
	case TabHarnesses:
		if v := p.raw.harn; v != nil {
			c := *v
			c.Rows = keep(v.Rows, func(r HarnessRow) bool { return match(r.Name, r.Display) })
			p.data.harn = &c
		}
	case TabBench:
		if v := p.raw.bench; v != nil {
			c := *v
			c.Rows = keep(v.Rows, func(r BenchRow) bool {
				via := make([]string, 0, len(r.Via))
				for _, x := range r.Via {
					via = append(via, x.Harness, x.GatewayKind, x.Engine)
				}
				return match(append(via, r.Model)...)
			})
			p.data.bench = &c
		}
	case TabRuns:
		if v := p.raw.status; v != nil {
			c := *v
			c.Runs = keep(v.Runs, func(r RunRow) bool { return match(r.ID, r.CLI, r.Model, r.Where, r.Outcome) })
			p.data.status = &c
		}
	case TabConfig:
		if v := p.raw.config; v != nil {
			c := *v
			c.Rows = keep(v.Rows, func(r [2]string) bool { return match(r[0], r[1]) })
			p.data.config = &c
		}
	case TabSkills:
		if v := p.raw.skills; v != nil {
			c := *v
			c.Rows = keep(v.Rows, func(r SkillRow) bool { return match(r.Name) })
			p.data.skills = &c
		}
	case TabMCP:
		if v := p.raw.mcp; v != nil {
			c := *v
			c.Rows = keep(v.Rows, func(r MCPRow) bool { return match(r.Name, r.Via) })
			p.data.mcp = &c
		}
	}
	if n := p.rowsOf(t); p.sel[t] >= n {
		p.sel[t] = max(n-1, 0)
	}
}

func keep[T any](rows []T, ok func(T) bool) []T {
	out := make([]T, 0, len(rows))
	for _, r := range rows {
		if ok(r) {
			out = append(out, r)
		}
	}
	return out
}

// filterLine is the filter as it is shown above the key hints, or nil.
func (p *Panel) filterLine() line {
	t := p.theme
	f := p.filter[p.tab]
	switch {
	case p.typing:
		return line{sg(t.Key, " /"), sg(t.Plain, " "+f), sg(t.Accent, "▏"), sg(t.Dim, "   "), sg(t.Key, "↵"), sg(t.Dim, " keep  "), sg(t.Key, "esc"), sg(t.Dim, " clear")}
	case f != "":
		return line{sg(t.Dim, " filter "), sg(t.Plain, f), sg(t.Dim, "   "), sg(t.Key, "/"), sg(t.Dim, " change  "), sg(t.Key, "esc"), sg(t.Dim, " clear")}
	}
	return nil
}
