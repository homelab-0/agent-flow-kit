package config

import (
	"bytes"
	"strings"

	"github.com/pelletier/go-toml/v2/unstable"
)

// entry is one key = value line or table header in a TOML document, with
// where it is, so the document can be edited in place (comments, order and
// spacing kept).
type entry struct {
	path string // dotted, for a key the table's path plus the key
	// comps are the key's components: "route.prefer" quoted is one
	// component, route.prefer bare is two. Matching uses these.
	comps []string
	// scope is the table header the expression sits under.
	scope []string
	table bool // a [table] header (or [[array]] header)
	array bool
	line  int
	// For a key: where its value is, and where its line ends.
	valStart, valEnd int
	// lineEnd is the offset just after the expression's last line.
	lineEnd int
	inline  bool // the value is an inline table or the key is dotted inside one
}

// scan lists a document's tables and keys. It returns the parser's error
// for a document that isn't valid TOML.
func scan(doc []byte) ([]entry, error) {
	var p unstable.Parser
	p.Reset(doc)
	var out []entry
	var cur []string
	for p.NextExpression() {
		n := p.Expression()
		switch n.Kind {
		case unstable.Table, unstable.ArrayTable:
			comps, first, _ := keyComps(n.Key())
			cur = comps
			e := entry{path: strings.Join(comps, "."), comps: comps, scope: comps, table: true, array: n.Kind == unstable.ArrayTable}
			if first != nil {
				e.line = p.Shape(first.Raw).Start.Line
				e.lineEnd = lineEndAt(doc, int(first.Raw.Offset))
			}
			out = append(out, e)
		case unstable.KeyValue:
			comps, first, last := keyComps(n.Key())
			full := append(append([]string(nil), cur...), comps...)
			v := n.Value()
			e := entry{path: strings.Join(full, "."), comps: full, scope: cur}
			if first != nil {
				e.line = p.Shape(first.Raw).Start.Line
			}
			start, end := valueSpan(doc, int(last.Raw.Offset+last.Raw.Length), v)
			e.valStart, e.valEnd = start, end
			e.lineEnd = lineEndAt(doc, end)
			e.inline = v.Kind == unstable.InlineTable
			out = append(out, e)
		}
	}
	return out, p.Error()
}

func keyComps(it unstable.Iterator) ([]string, *unstable.Node, *unstable.Node) {
	var parts []string
	var first, last *unstable.Node
	for it.Next() {
		k := it.Node()
		if first == nil {
			first = k
		}
		last = k
		parts = append(parts, string(k.Data))
	}
	return parts, first, last
}

// sameComps compares key components.
func sameComps(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// hasPrefixComps reports whether a starts with the components of b, and
// is longer.
func hasPrefixComps(a, b []string) bool {
	return len(a) > len(b) && sameComps(a[:len(b)], b)
}

// valueSpan is where a value's bytes are: from the first byte after the
// "=" that follows the key, to the end of the value. An array or inline
// table runs to its closing bracket.
func valueSpan(doc []byte, keyEnd int, v *unstable.Node) (int, int) {
	eq := bytes.IndexByte(doc[keyEnd:], '=')
	if eq < 0 {
		return -1, -1
	}
	i := keyEnd + eq + 1
	for i < len(doc) && (doc[i] == ' ' || doc[i] == '\t') {
		i++
	}
	switch v.Kind {
	case unstable.Array:
		return i, matchBracket(doc, i, '[', ']') + 1
	case unstable.InlineTable:
		return i, matchBracket(doc, i, '{', '}') + 1
	}
	if v.Raw.Length > 0 {
		end := int(v.Raw.Offset + v.Raw.Length)
		// A string's Raw is its contents; take the closing quotes too.
		if end < len(doc) && i < len(doc) && (doc[i] == '"' || doc[i] == '\'') {
			end = skipString(doc, i) + 1
		}
		return i, end
	}
	return i, lineEndAt(doc, i) - 1
}

// matchBracket finds the bracket closing the one at start, skipping
// strings and comments.
func matchBracket(doc []byte, start int, open, close byte) int {
	depth := 0
	for i := start; i < len(doc); i++ {
		switch c := doc[i]; c {
		case '"', '\'':
			i = skipString(doc, i)
		case '#':
			for i < len(doc) && doc[i] != '\n' {
				i++
			}
		case open:
			depth++
		case close:
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return len(doc) - 1
}

// skipString returns the offset of the last byte of the string that
// starts at i. A multi-line string may end with up to two extra quotes
// before its closing three ("""a"""" is a" then the closer), and in basic
// strings a backslash escapes the next byte.
func skipString(doc []byte, i int) int {
	q := doc[i]
	basic := q == '"'
	if i+2 < len(doc) && doc[i+1] == q && doc[i+2] == q {
		for j := i + 3; j < len(doc); j++ {
			if basic && doc[j] == '\\' {
				j++
				continue
			}
			if j+2 < len(doc) && doc[j] == q && doc[j+1] == q && doc[j+2] == q {
				end := j + 2
				// Up to two more quotes belong to the content.
				for k := 0; k < 2 && end+1 < len(doc) && doc[end+1] == q; k++ {
					end++
				}
				return end
			}
		}
		return len(doc) - 1
	}
	for j := i + 1; j < len(doc); j++ {
		if basic && doc[j] == '\\' {
			j++
			continue
		}
		if doc[j] == q || doc[j] == '\n' {
			return j
		}
	}
	return len(doc) - 1
}

func lineEndAt(doc []byte, off int) int {
	if off < 0 {
		return len(doc)
	}
	if i := bytes.IndexByte(doc[off:], '\n'); i >= 0 {
		return off + i + 1
	}
	return len(doc)
}

// lines maps every key and table to its line, for error messages.
func lines(entries []entry) map[string]int {
	m := map[string]int{}
	for _, e := range entries {
		if _, ok := m[e.path]; !ok {
			m[e.path] = e.line
		}
	}
	return m
}
