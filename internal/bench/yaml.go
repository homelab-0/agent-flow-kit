package bench

import (
	"errors"
	"strings"
)

// parseYAML reads the block YAML leaderboards are written in: nested
// mappings and lists ("- key: value"), plain or quoted scalars, comments
// and blank lines. Flow collections ([a, b], {a: 1}) and multi-line
// strings are kept as text. Every scalar is a string; a score is read as
// a number later. It is enough for a leaderboard file, not all of YAML.
func parseYAML(b []byte) (any, error) {
	var lines []yline
	for _, raw := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		t := strings.TrimRight(stripComment(raw), " \t")
		if strings.TrimSpace(t) == "" || t == "---" || t == "..." {
			continue
		}
		if strings.ContainsRune(t[:len(t)-len(strings.TrimLeft(t, " "))], '\t') {
			return nil, errors.New("YAML indented with tabs")
		}
		ind := len(t) - len(strings.TrimLeft(t, " "))
		lines = append(lines, yline{ind, t[ind:]})
	}
	if len(lines) == 0 {
		return nil, errors.New("empty YAML")
	}
	p := &yparser{lines: lines}
	v := p.block(lines[0].ind)
	if p.bad || p.i < len(p.lines) {
		return nil, errors.New("YAML this reader doesn't follow")
	}
	return v, nil
}

type yline struct {
	ind  int
	text string
}

type yparser struct {
	lines []yline
	i     int
	bad   bool
}

// block reads the node whose lines start at indent ind.
func (p *yparser) block(ind int) any {
	if p.i >= len(p.lines) {
		return nil
	}
	if isItem(p.lines[p.i].text) {
		return p.list(ind)
	}
	return p.mapping(ind)
}

func isItem(t string) bool { return t == "-" || strings.HasPrefix(t, "- ") }

func (p *yparser) list(ind int) []any {
	var out []any
	for p.i < len(p.lines) {
		l := p.lines[p.i]
		if l.ind != ind || !isItem(l.text) {
			break
		}
		rest := strings.TrimSpace(strings.TrimPrefix(l.text, "-"))
		if rest == "" {
			p.i++
			if p.i < len(p.lines) && p.lines[p.i].ind > ind {
				out = append(out, p.block(p.lines[p.i].ind))
			} else {
				out = append(out, nil)
			}
			continue
		}
		if _, _, ok := splitKey(rest); ok {
			// "- key: value" starts a mapping indented to where key is.
			p.lines[p.i] = yline{ind + (len(l.text) - len(rest)), rest}
			out = append(out, p.mapping(p.lines[p.i].ind))
			continue
		}
		out = append(out, scalar(rest))
		p.i++
	}
	return out
}

func (p *yparser) mapping(ind int) map[string]any {
	out := map[string]any{}
	for p.i < len(p.lines) {
		l := p.lines[p.i]
		if l.ind != ind || isItem(l.text) {
			// A list may sit at the same indent as its key.
			break
		}
		k, v, ok := splitKey(l.text)
		if !ok {
			p.bad = true
			p.i = len(p.lines)
			return out
		}
		p.i++
		if v != "" {
			out[k] = scalar(v)
			continue
		}
		switch {
		case p.i < len(p.lines) && p.lines[p.i].ind > ind:
			out[k] = p.block(p.lines[p.i].ind)
		case p.i < len(p.lines) && p.lines[p.i].ind == ind && isItem(p.lines[p.i].text):
			out[k] = p.list(ind)
		default:
			out[k] = nil
		}
	}
	return out
}

// splitKey splits "key: value" (the value may be empty).
func splitKey(t string) (string, string, bool) {
	if strings.HasPrefix(t, `"`) || strings.HasPrefix(t, `'`) {
		q := t[:1]
		end := strings.Index(t[1:], q)
		if end < 0 {
			return "", "", false
		}
		k, rest := t[1:1+end], t[2+end:]
		if !strings.HasPrefix(rest, ":") {
			return "", "", false
		}
		return k, strings.TrimSpace(rest[1:]), true
	}
	i := strings.Index(t, ": ")
	if i < 0 {
		if strings.HasSuffix(t, ":") {
			return strings.TrimSpace(t[:len(t)-1]), "", true
		}
		return "", "", false
	}
	return strings.TrimSpace(t[:i]), strings.TrimSpace(t[i+2:]), true
}

func scalar(s string) any {
	if len(s) >= 2 && (s[0] == '"' && s[len(s)-1] == '"' || s[0] == '\'' && s[len(s)-1] == '\'') {
		return s[1 : len(s)-1]
	}
	if s == "~" || s == "null" {
		return nil
	}
	return s
}

// stripComment drops a # comment outside quotes.
func stripComment(s string) string {
	var q rune
	for i, r := range s {
		switch {
		case q != 0:
			if r == q {
				q = 0
			}
		case r == '"' || r == '\'':
			if i == 0 || s[i-1] == ' ' || s[i-1] == ':' {
				q = r
			}
		case r == '#' && (i == 0 || s[i-1] == ' '):
			return s[:i]
		}
	}
	return s
}
