package tui

import (
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// seg is a run of text in one style; a line is a row of segs. Widths are
// counted on the text, so padding never depends on escape codes.
type seg struct {
	st lipgloss.Style
	s  string
}

type line []seg

func sg(st lipgloss.Style, s string) seg { return seg{st, s} }

func (l line) width() int {
	n := 0
	for _, s := range l {
		n += ansi.StringWidth(s.s)
	}
	return n
}

func (l line) plain() string {
	var b strings.Builder
	for _, s := range l {
		b.WriteString(s.s)
	}
	return b.String()
}

func (l line) render() string {
	var b strings.Builder
	for _, s := range l {
		if s.s == "" {
			continue
		}
		b.WriteString(s.st.Render(s.s))
	}
	return b.String()
}

// pad fills the line with spaces up to w cells.
func (l line) pad(w int, st lipgloss.Style) line {
	if n := l.width(); n < w {
		return append(append(line{}, l...), sg(st, strings.Repeat(" ", w-n)))
	}
	return l
}

// on puts every seg on a background (the selected row).
func (l line) on(bg lipgloss.Style) line {
	out := make(line, len(l))
	for i, s := range l {
		out[i] = seg{s.st.Background(bg.GetBackground()), s.s}
	}
	return out
}

// truncate cuts plain text to w cells, ending in … when it had to cut.
func truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if ansi.StringWidth(s) <= w {
		return s
	}
	return ansi.Truncate(s, w, "…")
}

// col fits text into a column of w cells: cut with … or padded.
func col(s string, w int) string {
	s = truncate(s, w)
	if n := ansi.StringWidth(s); n < w {
		s += strings.Repeat(" ", w-n)
	}
	return s
}

// wrap breaks text into lines of at most w cells, at spaces.
func wrap(s string, w int) []string {
	words := strings.Fields(s)
	var out []string
	cur := ""
	for _, word := range words {
		switch {
		case cur == "":
			cur = word
		case ansi.StringWidth(cur)+1+ansi.StringWidth(word) <= w:
			cur += " " + word
		default:
			out = append(out, cur)
			cur = word
		}
	}
	if cur != "" {
		out = append(out, cur)
	}
	for i := range out {
		out[i] = truncate(out[i], w)
	}
	return out
}

func join(ls []line) string {
	parts := make([]string, len(ls))
	for i, l := range ls {
		parts[i] = l.render()
	}
	return strings.Join(parts, "\n")
}
