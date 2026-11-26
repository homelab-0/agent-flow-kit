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
	for _, e := range entries {
		if e.table || e.path != key {
			continue
		}
		if e.valStart < 0 {
			return nil, fmt.Errorf("%s: can't find its value to replace", key)
		}
		return splice(doc, e.valStart, e.valEnd, literal), nil
	}
	for _, e := range entries {
		if !e.table && strings.HasPrefix(key, e.path+".") && e.inline {
			return nil, fmt.Errorf("%s is inside the inline table %s; use afk config edit", key, e.path)
		}
		if e.table && e.array && strings.HasPrefix(key, e.path+".") {
			return nil, fmt.Errorf("%s is inside the array of tables [[%s]]; use afk config edit", key, e.path)
		}
	}
	table, name := "", key
	if i := strings.LastIndex(key, "."); i >= 0 {
		table, name = key[:i], key[i+1:]
	}
	line := name + " = " + literal + "\n"
	if table == "" {
		// A top-level key goes before the first table.
		for _, e := range entries {
			if e.table {
				at := lineStart(doc, e.lineEnd-1)
				return splice(doc, at, at, line), nil
			}
		}
		return appendLine(doc, line), nil
	}
	end, found := -1, false
	in := ""
	for _, e := range entries {
		if e.table {
			in = e.path
		}
		if in == table && (e.table || strings.HasPrefix(e.path, table+".")) {
			found = true
			if e.lineEnd > end {
				end = e.lineEnd
			}
		}
	}
	if found {
		return splice(doc, end, end, line), nil
	}
	out := doc
	if len(bytes.TrimSpace(out)) > 0 {
		out = appendLine(out, "\n")
	}
	return appendLine(out, "["+table+"]\n"+line), nil
}

func splice(doc []byte, from, to int, s string) []byte {
	out := make([]byte, 0, len(doc)+len(s))
	out = append(out, doc[:from]...)
	out = append(out, s...)
	return append(out, doc[to:]...)
}

func appendLine(doc []byte, s string) []byte {
	out := append([]byte(nil), doc...)
	if len(out) > 0 && out[len(out)-1] != '\n' {
		out = append(out, '\n')
	}
	return append(out, s...)
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
