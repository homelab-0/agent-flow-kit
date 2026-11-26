package config

import (
	"bytes"
	"fmt"
	"strconv"
	"strings"
)

// SetValue sets one key in a TOML document and keeps everything else as
// it was: comments, key order, blank lines and spacing. An existing value
// is replaced in place; a new key goes at the end of its table, and a new
// table at the end of the document. literal is the value as TOML
// (EncodeValue makes one).
func SetValue(doc []byte, key, literal string) ([]byte, error) {
	entries, err := scan(doc)
	if err != nil {
		return nil, err
	}
	want := strings.Split(key, ".")
	for _, e := range entries {
		if e.table || !sameComps(e.comps, want) {
			continue
		}
		if e.valStart < 0 {
			return nil, fmt.Errorf("%s: can't find its value to replace", key)
		}
		return splice(doc, e.valStart, e.valEnd, literal), nil
	}
	for _, e := range entries {
		if !e.table && e.inline && hasPrefixComps(want, e.comps) {
			return nil, fmt.Errorf("%s is inside the inline table %s; use afk config edit", key, e.path)
		}
		if e.table && e.array && hasPrefixComps(want, e.comps) {
			return nil, fmt.Errorf("%s is inside the array of tables [[%s]]; use afk config edit", key, e.path)
		}
	}
	table, name := want[:len(want)-1], want[len(want)-1]
	if len(table) == 0 {
		// A top-level key goes before the first table.
		for _, e := range entries {
			if e.table {
				return insertLine(doc, lineStart(doc, e.lineEnd-1), name+" = "+literal), nil
			}
		}
		return insertLine(doc, len(doc), name+" = "+literal), nil
	}
	// The table's own header: the new key goes after its last key.
	end, found := -1, false
	for _, e := range entries {
		if sameComps(e.scope, table) && (e.table || len(e.comps) > len(table)) {
			found = true
			if e.lineEnd > end {
				end = e.lineEnd
			}
		}
	}
	if found {
		return insertLine(doc, end, name+" = "+literal), nil
	}
	// No header, but dotted keys already define the table (route.prefer =
	// ... at the top, or work.url = ... under [gateway]): a header would
	// redefine it, so the key goes next to them, dotted the same way.
	var last *entry
	for i := range entries {
		e := &entries[i]
		if !e.table && hasPrefixComps(e.comps, table) && hasPrefixComps(table, e.scope) || (!e.table && hasPrefixComps(e.comps, table) && len(e.scope) == 0) {
			last = e
		}
	}
	if last != nil {
		rel := want[len(last.scope):]
		return insertLine(doc, last.lineEnd, strings.Join(rel, ".")+" = "+literal), nil
	}
	out := doc
	if len(bytes.TrimSpace(out)) > 0 {
		out = insertLine(out, len(out), "")
	}
	return insertLine(insertLine(out, len(out), "["+strings.Join(table, ".")+"]"), -1, name+" = "+literal), nil
}

// insertLine puts one line at offset at (-1: the end), starting it on a
// new line when the byte before isn't a newline, so it can never land in
// a comment or run into the previous value.
func insertLine(doc []byte, at int, line string) []byte {
	if at < 0 || at > len(doc) {
		at = len(doc)
	}
	s := line + "\n"
	if at > 0 && doc[at-1] != '\n' {
		s = "\n" + s
	}
	return splice(doc, at, at, s)
}

func splice(doc []byte, from, to int, s string) []byte {
	out := make([]byte, 0, len(doc)+len(s))
	out = append(out, doc[:from]...)
	out = append(out, s...)
	return append(out, doc[to:]...)
}

func lineStart(doc []byte, off int) int {
	if off > len(doc) {
		off = len(doc)
	}
	return bytes.LastIndexByte(doc[:off], '\n') + 1
}

// EncodeValue turns a command-line value into TOML for a key's type:
// strings are quoted, a list is comma-separated, booleans and numbers are
// checked.
func EncodeValue(key, raw string) (string, error) {
	switch KeyType(key) {
	case "string":
		return quote(raw), nil
	case "bool":
		b, err := strconv.ParseBool(raw)
		if err != nil {
			return "", fmt.Errorf("%s takes true or false", key)
		}
		return strconv.FormatBool(b), nil
	case "int":
		n, err := strconv.Atoi(raw)
		if err != nil {
			return "", fmt.Errorf("%s takes a whole number", key)
		}
		return strconv.Itoa(n), nil
	case "float":
		f, err := strconv.ParseFloat(raw, 64)
		if err != nil {
			return "", fmt.Errorf("%s takes a number", key)
		}
		return strconv.FormatFloat(f, 'f', -1, 64), nil
	case "strings":
		var items []string
		for _, s := range strings.Split(raw, ",") {
			if s = strings.TrimSpace(s); s != "" {
				items = append(items, quote(s))
			}
		}
		return "[" + strings.Join(items, ", ") + "]", nil
	}
	return "", fmt.Errorf("%s is not a config key (see afk config get)", key)
}

// quote is a TOML basic string.
func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\t':
			b.WriteString(`\t`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if r < 0x20 || r == 0x7f {
				fmt.Fprintf(&b, `\u%04X`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
