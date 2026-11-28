package mcp

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// format reads and writes one kind of CLI MCP config.
type format interface {
	// entry is what AFK writes for a server, as JSON-like data; an error
	// means this CLI can't express the server the way it's set up.
	entry(s Server) (map[string]any, error)
	// read returns the file's servers by name. managed, when not nil,
	// lists the names inside AFK's own section (a CLI where AFK keeps
	// one); outside it every entry is the user's.
	read(b []byte) (entries map[string]any, managed map[string]bool, err error)
	// write sets and removes servers and returns the new file.
	write(b []byte, set map[string]map[string]any, del []string) ([]byte, error)
}

func formatFor(name string) (format, bool) {
	switch name {
	case "claude-json":
		return jsonFormat{key: "mcpServers", mk: claudeEntry}, true
	case "gemini-json":
		return jsonFormat{key: "mcpServers", mk: geminiEntry}, true
	case "copilot-json":
		return jsonFormat{key: "mcpServers", mk: copilotEntry}, true
	case "opencode-json":
		return jsonFormat{key: "mcp", mk: opencodeEntry}, true
	case "codex-toml":
		return codexFormat{}, true
	}
	return nil, false
}

// canon is a value's canonical JSON hash: equal entries hash the same
// whatever their key order or spacing.
func canon(v any) string {
	b, err := json.Marshal(normalize(v))
	if err != nil {
		return ""
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// sameEntry says a CLI's entry is the one AFK would write, counting the
// keys a CLI fills in by default as written: Claude Code reads a command
// entry without "type" as stdio, and no args or env as none.
func sameEntry(cur any, desired map[string]any) bool {
	if canon(cur) == canon(desired) {
		return true
	}
	m, ok := cur.(map[string]any)
	if !ok {
		return false
	}
	filled := map[string]any{}
	for k, v := range m {
		filled[k] = v
	}
	if _, has := filled["type"]; !has && desired["type"] == "stdio" {
		if _, cmd := filled["command"]; cmd {
			filled["type"] = "stdio"
		}
	}
	if a, ok := desired["args"].([]any); ok && len(a) == 0 {
		if _, has := filled["args"]; !has {
			filled["args"] = []any{}
		}
	}
	return canon(filled) == canon(desired)
}

// normalize turns decoded JSON or TOML into plain maps, slices and
// strings, so the two hash alike.
func normalize(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, e := range x {
			out[k] = normalize(e)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = normalize(e)
		}
		return out
	case []string:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = e
		}
		return out
	case map[string]string:
		out := map[string]any{}
		for k, e := range x {
			out[k] = e
		}
		return out
	case json.Number:
		return x.String()
	case int64, float64, int:
		return fmt.Sprint(x)
	}
	return v
}

// --- entries for each CLI ---------------------------------------------------

func envMap(names []string, ref func(string) string) map[string]any {
	m := map[string]any{}
	for _, n := range names {
		m[n] = ref(n)
	}
	return m
}

func strs(s []string) []any {
	out := make([]any, len(s))
	for i, x := range s {
		out[i] = x
	}
	return out
}

func claudeEntry(s Server) (map[string]any, error) {
	ref := func(n string) string { return "${" + n + "}" }
	if s.Kind == "http" {
		e := map[string]any{"type": "http", "url": s.URL}
		if s.BearerEnv != "" {
			e["headers"] = map[string]any{"Authorization": "Bearer " + ref(s.BearerEnv)}
		}
		return e, nil
	}
	e := map[string]any{"type": "stdio", "command": s.Command, "args": strs(s.Args)}
	if len(s.Env) > 0 {
		e["env"] = envMap(s.Env, ref)
	}
	return e, nil
}

func geminiEntry(s Server) (map[string]any, error) {
	ref := func(n string) string { return "$" + n }
	if s.Kind == "http" {
		e := map[string]any{"httpUrl": s.URL}
		if s.BearerEnv != "" {
			e["headers"] = map[string]any{"Authorization": "Bearer " + ref(s.BearerEnv)}
		}
		return e, nil
	}
	e := map[string]any{"command": s.Command, "args": strs(s.Args)}
	if len(s.Env) > 0 {
		e["env"] = envMap(s.Env, ref)
	}
	return e, nil
}

func opencodeEntry(s Server) (map[string]any, error) {
	ref := func(n string) string { return "{env:" + n + "}" }
	if s.Kind == "http" {
		e := map[string]any{"type": "remote", "url": s.URL, "enabled": true}
		if s.BearerEnv != "" {
			e["headers"] = map[string]any{"Authorization": "Bearer " + ref(s.BearerEnv)}
		}
		return e, nil
	}
	e := map[string]any{"type": "local", "command": strs(append([]string{s.Command}, s.Args...)), "enabled": true}
	if len(s.Env) > 0 {
		e["environment"] = envMap(s.Env, ref)
	}
	return e, nil
}

func copilotEntry(s Server) (map[string]any, error) {
	// AFK doesn't know a way to hand Copilot CLI a token by variable
	// name, and never writes a token itself.
	if s.BearerEnv != "" || len(s.Env) > 0 {
		return nil, errors.New("copilot: AFK can't pass a token or env by name here")
	}
	if s.Kind == "http" {
		return map[string]any{"type": "http", "url": s.URL, "tools": []any{"*"}}, nil
	}
	return map[string]any{"type": "local", "command": s.Command, "args": strs(s.Args), "tools": []any{"*"}}, nil
}

// --- JSON files ---------------------------------------------------------------

// member is one key of a JSON object, its value kept as written.
type member struct {
	key string
	val json.RawMessage
}

// members reads a JSON object's keys in order.
func members(b []byte) ([]member, error) {
	if len(bytes.TrimSpace(b)) == 0 {
		return nil, nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	t, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if d, ok := t.(json.Delim); !ok || d != '{' {
		return nil, errors.New("not a JSON object")
	}
	var out []member
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return nil, err
		}
		k, _ := t.(string)
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, err
		}
		out = append(out, member{k, v})
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("text after the JSON object")
	}
	return out, nil
}

func encodeMembers(ms []member) []byte {
	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, m := range ms {
		if i > 0 {
			buf.WriteByte(',')
		}
		k, _ := json.Marshal(m.key)
		buf.Write(k)
		buf.WriteByte(':')
		buf.Write(m.val)
	}
	buf.WriteByte('}')
	return buf.Bytes()
}

type jsonFormat struct {
	key string
	mk  func(Server) (map[string]any, error)
}

func (f jsonFormat) entry(s Server) (map[string]any, error) { return f.mk(s) }

func (f jsonFormat) read(b []byte) (map[string]any, map[string]bool, error) {
	top, err := members(b)
	if err != nil {
		return nil, nil, err
	}
	out := map[string]any{}
	for _, m := range top {
		if m.key != f.key {
			continue
		}
		dec := json.NewDecoder(bytes.NewReader(m.val))
		dec.UseNumber()
		var servers map[string]any
		if err := dec.Decode(&servers); err != nil {
			return nil, nil, fmt.Errorf("%q is not an object: %w", f.key, err)
		}
		for k, v := range servers {
			out[k] = v
		}
	}
	return out, nil, nil
}

func (f jsonFormat) write(b []byte, set map[string]map[string]any, del []string) ([]byte, error) {
	top, err := members(b)
	if err != nil {
		return nil, err
	}
	at := -1
	for i, m := range top {
		if m.key == f.key {
			at = i
		}
	}
	var inner []member
	if at >= 0 {
		if inner, err = members(top[at].val); err != nil {
			return nil, fmt.Errorf("%q: %w", f.key, err)
		}
	}
	gone := map[string]bool{}
	for _, d := range del {
		gone[d] = true
	}
	var kept []member
	done := map[string]bool{}
	for _, m := range inner {
		switch {
		case gone[m.key]:
		case set[m.key] != nil:
			v, err := json.Marshal(set[m.key])
			if err != nil {
				return nil, err
			}
			kept = append(kept, member{m.key, v})
			done[m.key] = true
		default:
			kept = append(kept, m)
		}
	}
	var names []string
	for n := range set {
		if !done[n] {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	for _, n := range names {
		v, err := json.Marshal(set[n])
		if err != nil {
			return nil, err
		}
		kept = append(kept, member{n, v})
	}
	val := encodeMembers(kept)
	if at >= 0 {
		top[at].val = val
	} else {
		top = append(top, member{f.key, val})
	}
	var out bytes.Buffer
	if err := json.Indent(&out, encodeMembers(top), "", "  "); err != nil {
		return nil, err
	}
	out.WriteByte('\n')
	return out.Bytes(), nil
}

// --- Codex config.toml -------------------------------------------------------

// Codex keeps comments and layout in config.toml, so AFK never rewrites
// the file: its servers sit in one marked section at the end, and only
// that section changes.
const (
	codexBegin = "# >>> afk mcp: servers from ~/.config/afk/mcp.toml (afk mcp sync). Edits here show as drift. >>>"
	codexEnd   = "# <<< afk mcp <<<"
)

type codexFormat struct{}

func (codexFormat) entry(s Server) (map[string]any, error) {
	if s.Kind == "http" {
		e := map[string]any{"url": s.URL}
		if s.BearerEnv != "" {
			e["bearer_token_env_var"] = s.BearerEnv
		}
		return e, nil
	}
	e := map[string]any{"command": s.Command, "args": strs(s.Args)}
	if len(s.Env) > 0 {
		e["env_vars"] = strs(s.Env)
	}
	return e, nil
}

// splitCodex cuts the file around AFK's section.
func splitCodex(b []byte) (pre, block, post string, found bool, err error) {
	s := string(b)
	i := strings.Index(s, codexBegin)
	if i < 0 {
		return s, "", "", false, nil
	}
	j := strings.Index(s[i:], codexEnd)
	if j < 0 {
		return "", "", "", false, errors.New("AFK's section in config.toml has no end line; fix or remove it by hand")
	}
	j += i
	return s[:i], s[i+len(codexBegin) : j], s[j+len(codexEnd):], true, nil
}

var reCodexHead = regexp.MustCompile(`(?m)^\s*\[\s*mcp_servers\.("?)([A-Za-z0-9_-]+)("?)\s*(\]|\.)`)

// chunks cuts AFK's section into its servers' tables, in order.
func chunks(block string) (names []string, text map[string]string) {
	text = map[string]string{}
	locs := reCodexHead.FindAllStringSubmatchIndex(block, -1)
	for i, l := range locs {
		name := block[l[4]:l[5]]
		end := len(block)
		if i+1 < len(locs) {
			end = locs[i+1][0]
		}
		if _, ok := text[name]; !ok {
			names = append(names, name)
		}
		text[name] += block[l[0]:end]
	}
	return names, text
}

func (codexFormat) read(b []byte) (map[string]any, map[string]bool, error) {
	var doc map[string]any
	if err := toml.Unmarshal(b, &doc); err != nil {
		return nil, nil, err
	}
	out := map[string]any{}
	if ms, ok := doc["mcp_servers"].(map[string]any); ok {
		for k, v := range ms {
			out[k] = v
		}
	}
	_, block, _, _, err := splitCodex(b)
	if err != nil {
		return nil, nil, err
	}
	names, _ := chunks(block)
	managed := map[string]bool{}
	for _, n := range names {
		managed[n] = true
	}
	return out, managed, nil
}

func tomlString(s string) string {
	b, _ := json.Marshal(s) // a JSON string is a TOML basic string
	return string(b)
}

func renderCodex(name string, e map[string]any) string {
	var sb strings.Builder
	sb.WriteString("[mcp_servers." + name + "]\n")
	keys := make([]string, 0, len(e))
	for k := range e {
		keys = append(keys, k)
	}
	// command and url first, the way people write them.
	rank := map[string]int{"command": 0, "url": 0, "args": 1}
	sort.Slice(keys, func(i, j int) bool {
		ri, oki := rank[keys[i]]
		rj, okj := rank[keys[j]]
		if !oki {
			ri = 2
		}
		if !okj {
			rj = 2
		}
		if ri != rj {
			return ri < rj
		}
		return keys[i] < keys[j]
	})
	for _, k := range keys {
		switch v := e[k].(type) {
		case string:
			sb.WriteString(k + " = " + tomlString(v) + "\n")
		case []any:
			parts := make([]string, len(v))
			for i, x := range v {
				parts[i] = tomlString(fmt.Sprint(x))
			}
			sb.WriteString(k + " = [" + strings.Join(parts, ", ") + "]\n")
		}
	}
	return sb.String()
}

func (codexFormat) write(b []byte, set map[string]map[string]any, del []string) ([]byte, error) {
	pre, block, post, found, err := splitCodex(b)
	if err != nil {
		return nil, err
	}
	names, text := chunks(block)
	gone := map[string]bool{}
	for _, d := range del {
		gone[d] = true
	}
	var parts []string
	done := map[string]bool{}
	for _, n := range names {
		switch {
		case gone[n]:
		case set[n] != nil:
			parts = append(parts, renderCodex(n, set[n]))
			done[n] = true
		default:
			parts = append(parts, strings.TrimRight(text[n], "\n")+"\n")
		}
	}
	var add []string
	for n := range set {
		if !done[n] {
			add = append(add, n)
		}
	}
	sort.Strings(add)
	for _, n := range add {
		parts = append(parts, renderCodex(n, set[n]))
	}
	var out string
	if len(parts) == 0 {
		// Nothing left: take the section out.
		out = strings.TrimRight(pre, "\n")
		if rest := strings.TrimLeft(post, "\n"); rest != "" {
			out += "\n\n" + rest
		} else if out != "" {
			out += "\n"
		}
	} else {
		sec := codexBegin + "\n" + strings.Join(parts, "\n") + codexEnd
		if found {
			out = pre + sec + post
		} else {
			out = strings.TrimRight(pre, "\n")
			if out != "" {
				out += "\n\n"
			}
			out += sec + "\n"
		}
	}
	// Never hand Codex a file it can't read.
	var check map[string]any
	if err := toml.Unmarshal([]byte(out), &check); err != nil {
		return nil, fmt.Errorf("the new config.toml would not parse (%v); nothing was written", err)
	}
	return []byte(out), nil
}
