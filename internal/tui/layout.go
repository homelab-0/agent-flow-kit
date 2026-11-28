package tui

import "strings"

// Shared pieces the tabs are built from, so every tab looks alike: a list
// beside a detail panel, group headings, status dots and label/value rows.

// twoPaneMin is the narrowest screen that puts the detail beside the list;
// below it the detail goes under the list.
const twoPaneMin = 96

// twoPane sets the list (lw cells wide) beside the detail, with a rule
// between them.
func (t Theme) twoPane(list []line, lw int, detail []line, w int) []line {
	var out []line
	for i := 0; i < max(len(list), len(detail)); i++ {
		var l line
		if i < len(list) {
			l = fitLine(list[i], lw)
		}
		l = l.pad(lw, t.Plain)
		l = append(l, sg(t.Border, " │ "))
		if i < len(detail) {
			l = append(l, fitLine(detail[i], max(w-lw-3, 1))...)
		}
		out = append(out, l)
	}
	return out
}

// groupHead is a group's heading in a list: its name and how many.
func (t Theme) groupHead(name string, n int) line {
	return line{sg(t.Accent.Bold(true), " "+strings.ToUpper(name)), sg(t.Dim, "  "+itoaN(n))}
}

// dot is a state as a coloured dot: ok ●, partly known ◐, bad ●, not
// reported ○.
func (t Theme) dot(state string) seg {
	switch state {
	case "ok":
		return sg(t.OK, "●")
	case "partly":
		return sg(t.Warn, "◐")
	case "bad":
		return sg(t.Bad, "●")
	}
	return sg(t.Dim, "○")
}

// field is a label and its value in a detail panel.
func (t Theme) field(label string, value ...seg) line {
	return append(line{sg(t.Dim, col(label, 10))}, value...)
}

// wrapField is a label with a long value wrapped under itself.
func (t Theme) wrapField(label, value string, w int) []line {
	var out []line
	for i, l := range wrap(value, max(w-10, 10)) {
		if i == 0 {
			out = append(out, t.field(label, sg(t.Plain, l)))
		} else {
			out = append(out, line{sg(t.Plain, strings.Repeat(" ", 10)+l)})
		}
	}
	return out
}

func itoaN(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
