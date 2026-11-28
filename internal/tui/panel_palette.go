package tui

import (
	"strings"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
)

// The tabs' command palette: ctrl+p (or :) opens a list of everything the
// panel can do, narrowed as you type, so nothing needs to be remembered.

// palItem is one thing the palette can do.
type palItem struct {
	label, desc string
	tab         Tab      // go to this tab (noTab: none)
	argv        []string // or run this afk subcommand
	quit        bool
}

// palette is the open palette.
type palette struct {
	text string
	sel  int
}

func (p *Panel) palItems() []palItem {
	var out []palItem
	for i, n := range tabNames {
		out = append(out, palItem{label: "Go to " + n, desc: tabBlurbs[i], tab: Tab(i)})
	}
	out = append(out, palItem{label: "Update all agent CLIs", desc: "every installed CLI with something newer; asks once", tab: noTab, argv: []string{"harness", "update", "--all"}})
	if h := p.raw.harn; h != nil {
		for _, r := range h.Rows {
			if r.Installed && r.Update != "" {
				out = append(out, palItem{label: "Update " + r.Name, desc: r.Update, tab: noTab, argv: []string{"harness", "update", r.Name}})
			}
		}
		for _, r := range h.Rows {
			if r.Installed {
				out = append(out, palItem{label: "Sign in to " + r.Name, desc: "its own sign-in, in this terminal", tab: noTab, argv: []string{"harness", "login", r.Name}})
			}
		}
	}
	out = append(out,
		palItem{label: "Update AFK", desc: "the newest release, the way AFK was installed", tab: noTab, argv: []string{"update"}},
		palItem{label: "Sync benchmarks", desc: "fetch the latest scores", tab: noTab, argv: []string{"bench", "sync"}},
		palItem{label: "Edit config.toml", desc: "in your editor", tab: noTab, argv: []string{"config", "edit"}},
		palItem{label: "Quit AFK", tab: noTab, quit: true},
	)
	q := strings.ToLower(strings.TrimSpace(p.pal.text))
	if q == "" {
		return out
	}
	var first, then []palItem
	for _, it := range out {
		l := strings.ToLower(it.label)
		switch {
		case strings.HasPrefix(l, q) || strings.Contains(l, " "+q):
			first = append(first, it)
		case fuzzy(l+" "+strings.ToLower(it.desc), q):
			then = append(then, it)
		}
	}
	return append(first, then...)
}

// fuzzy says whether every rune of q appears in s, in order.
func fuzzy(s, q string) bool {
	for _, r := range q {
		i := strings.IndexRune(s, r)
		if i < 0 {
			return false
		}
		s = s[i+utf8.RuneLen(r):]
	}
	return true
}

// palKey handles a key while the palette is open.
func (p *Panel) palKey(k string) tea.Cmd {
	items := p.palItems()
	switch k {
	case "esc", "ctrl+p":
		p.pal = nil
		return nil
	case "up", "ctrl+k":
		if len(items) > 0 {
			p.pal.sel = (p.pal.sel - 1 + len(items)) % len(items)
		}
		return nil
	case "down", "ctrl+j", "tab":
		if len(items) > 0 {
			p.pal.sel = (p.pal.sel + 1) % len(items)
		}
		return nil
	case "enter":
		if len(items) == 0 {
			return nil
		}
		it := items[min(p.pal.sel, len(items)-1)]
		p.pal = nil
		switch {
		case it.quit:
			p.quit = true
		case it.argv != nil:
			return p.run(it.argv...)
		case it.tab == TabRoute:
			return p.switchTo(TabRoute)
		default:
			return p.switchTo(it.tab)
		}
		return nil
	case "backspace":
		if t := p.pal.text; t != "" {
			_, n := utf8.DecodeLastRuneInString(t)
			p.pal.text = t[:len(t)-n]
		}
	case "space":
		p.pal.text += " "
	case "ctrl+u":
		p.pal.text = ""
	default:
		if utf8.RuneCountInString(k) != 1 {
			return nil
		}
		p.pal.text += k
	}
	p.pal.sel = 0
	return nil
}

// palLines is the palette, drawn over the top of the tab's body.
func (p *Panel) palLines(w int) []line {
	t := p.theme
	bw := min(w-4, 72)
	items := p.palItems()
	sel := min(p.pal.sel, max(len(items)-1, 0))
	out := []line{
		t.top("Commands", bw, t.Accent),
		t.boxLine(bw, t.Accent, line{sg(t.Accent, "› "), sg(t.Plain, p.pal.text), sg(t.Accent, "▏")}),
		t.boxLine(bw, t.Accent, nil),
	}
	const rows = 12
	start := 0
	if sel >= rows {
		start = sel - rows + 1
	}
	if len(items) == 0 {
		out = append(out, t.boxLine(bw, t.Accent, line{sg(t.Dim, "nothing matches")}))
	}
	for i := start; i < len(items) && i < start+rows; i++ {
		it := items[i]
		row := line{sg(t.Plain, col(it.label, 26)), sg(t.Dim, it.desc)}
		row = fitLine(row, bw-5)
		if i == sel {
			row = append(line{sg(t.Accent, "▌")}, row.pad(bw-5, t.Plain).on(t.SelBG)...)
		} else {
			row = append(line{sg(t.Plain, " ")}, row...)
		}
		out = append(out, t.boxLine(bw, t.Accent, row))
	}
	out = append(out, t.bottom(bw, t.Accent))
	for i := range out {
		out[i] = append(line{sg(t.Plain, "  ")}, out[i]...)
	}
	return out
}
