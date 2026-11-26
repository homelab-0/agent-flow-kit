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
	path  string // dotted, for a key the table's path plus the key
	table bool   // a [table] header (or [[array]] header)
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
	cur := ""
	for p.NextExpression() {
		n := p.Expression()
		switch n.Kind {
		case unstable.Table, unstable.ArrayTable:
			keys, first := keyOf(n.Key())
			cur = keys
			e := entry{path: keys, table: true, array: n.Kind == unstable.ArrayTable}
			if first != nil {
				e.line = p.Shape(first.Raw).Start.Line
				e.lineEnd = lineEndAt(doc, int(first.Raw.Offset))
			}
			out = append(out, e)
		case unstable.KeyValue:
			keys, first, last := keyOf3(n.Key())
			full := keys
			if cur != "" {
				full = cur + "." + keys
			}
			v := n.Value()
			e := entry{path: full}
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

func keyOf(it unstable.Iterator) (string, *unstable.Node) {
	k, f, _ := keyOf3(it)
	return k, f
}

func keyOf3(it unstable.Iterator) (string, *unstable.Node, *unstable.Node) {
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
	return strings.Join(parts, "."), first, last
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

func skipString(doc []byte, i int) int {
	q := doc[i]
	triple := i+2 < len(doc) && doc[i+1] == q && doc[i+2] == q
	if triple {
		end := bytes.Index(doc[i+3:], []byte{q, q, q})
		if end < 0 {
			return len(doc) - 1
		}
		return i + 3 + end + 2
	}
	for j := i + 1; j < len(doc); j++ {
		if doc[j] == '\\' && q == '"' {
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
