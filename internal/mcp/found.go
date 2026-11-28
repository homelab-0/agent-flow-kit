package mcp

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strings"
)

// Found is a server in a CLI's own MCP config that mcp.toml doesn't list
// and AFK didn't write: one you added to that CLI yourself.
type Found struct {
	Name string `json:"name"`
	// In are the CLIs whose config has a server of this name, and Files
	// their config files, in the same order.
	In    []string `json:"in"`
	Files []string `json:"files"`
	// Server is what importing adds to mcp.toml (the first CLI's entry);
	// Why says why it can't be imported, and is "" when it can.
	Server Server `json:"server"`
	Why    string `json:"why,omitempty"`
	// Left are the parts of the entry AFK doesn't copy: values written
	// into the CLI's config (a token, an env value), never read by AFK.
	Left []string `json:"left,omitempty"`
	// Differs says the CLIs' entries aren't the same; the first one is
	// what is imported.
	Differs bool `json:"differs,omitempty"`
}

// Where is how the server is reached, for people: its URL or command.
func (f Found) Where() string {
	if f.Server.Kind == "http" {
		return f.Server.URL
	}
	return strings.TrimSpace(f.Server.Command + " " + strings.Join(f.Server.Args, " "))
}

// Found lists the servers in the CLIs' own MCP configs that AFK could
// take on. It only reads.
func (e Env) Found(targets []Target) ([]Found, error) {
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	listed, _, err := e.servers()
	if err != nil {
		return nil, err
	}
	have := map[string]bool{}
	for _, s := range listed {
		have[s.Name] = true
	}
	byName := map[string]*Found{}
	var order []string
	hash := map[string]string{}
	for _, t := range targets {
		f := readTarget(t)
		if f.err != nil {
			continue
		}
		names := make([]string, 0, len(f.entries))
		for n := range f.entries {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			_, ours := st.Managed[key(t.Harness, n)]
			if f.managed != nil {
				ours = f.managed[n]
			}
			if ours || have[n] {
				continue
			}
			raw, _ := f.entries[n].(map[string]any)
			fd := byName[n]
			if fd == nil {
				fd = &Found{Name: n}
				byName[n] = fd
				order = append(order, n)
				c, left, err := fromEntry(t.Format, n, raw)
				fd.Left = left
				if err == nil {
					fd.Server, err = resolve(c, "", nil)
				}
				if err != nil {
					fd.Why = err.Error()
					fd.Server = Server{Name: n, Kind: c.kind(), URL: c.URL}
					if len(c.Command) > 0 {
						fd.Server.Command, fd.Server.Args = c.Command[0], c.Command[1:]
					}
				}
				hash[n] = canon(fd.Server)
			} else if c, _, err := fromEntry(t.Format, n, raw); err == nil {
				if s, err := resolve(c, "", nil); err != nil || canon(s) != hash[n] {
					fd.Differs = true
				}
			}
			fd.In = append(fd.In, t.Harness)
			fd.Files = append(fd.Files, t.File)
		}
	}
	out := make([]Found, 0, len(order))
	for _, n := range order {
		out = append(out, *byName[n])
	}
	return out, nil
}

// Import adds the named found servers to mcp.toml (every importable one
// when names is empty) and returns the names it added. The CLIs' own
// files are not changed: a sync later takes over entries that match and
// leaves the rest to you.
func (e Env) Import(targets []Target, names []string) ([]string, error) {
	if e.Project != "" {
		return nil, errors.New("import adds to mcp.toml, not to a project's .mcp.json")
	}
	found, err := e.Found(targets)
	if err != nil {
		return nil, err
	}
	want := map[string]bool{}
	for _, n := range names {
		want[n] = true
	}
	var done []string
	for _, f := range found {
		if len(names) > 0 && !want[f.Name] {
			continue
		}
		delete(want, f.Name)
		if f.Why != "" {
			if len(names) > 0 {
				return done, fmt.Errorf("%s can't be imported: %s", f.Name, f.Why)
			}
			continue
		}
		if err := AddToConfig(e.Config, e.Gateways, f.Server); err != nil {
			return done, err
		}
		done = append(done, f.Name)
	}
	for n := range want {
		return done, fmt.Errorf("no server named %s in your CLIs' own MCP configs", n)
	}
	return done, nil
}

func (c ServerConfig) kind() string {
	if c.URL != "" {
		return "http"
	}
	return "stdio"
}

// A variable reference in any CLI's syntax: ${NAME}, $NAME, {env:NAME}.
var reAnyRef = regexp.MustCompile(`^(?:\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)|\{env:([A-Za-z_][A-Za-z0-9_]*)\})$`)

func refName(v string) string {
	m := reAnyRef.FindStringSubmatch(v)
	if m == nil {
		return ""
	}
	return m[1] + m[2] + m[3]
}

// fromEntry reads one CLI entry back into a [[server]]. left lists what
// isn't copied (values written in the CLI's file); an error says why the
// entry can't be a server AFK manages.
func fromEntry(format, name string, e map[string]any) (c ServerConfig, left []string, err error) {
	c.Name = name
	str := func(k string) string { s, _ := e[k].(string); return s }
	list := func(k string) []string {
		var out []string
		if a, ok := e[k].([]any); ok {
			for _, x := range a {
				if s, ok := x.(string); ok {
					out = append(out, s)
				}
			}
		}
		return out
	}
	envFrom := func(k string) {
		m, _ := e[k].(map[string]any)
		names := make([]string, 0, len(m))
		for n := range m {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			v, _ := m[n].(string)
			if r := refName(v); r != "" && r != n {
				left = append(left, "env "+n+" (set from $"+r+")")
				continue
			} else if r == "" {
				left = append(left, "env "+n+" (its value is written in the file)")
			}
			c.Env = append(c.Env, n)
		}
	}
	headers := func(k string) {
		m, _ := e[k].(map[string]any)
		for h, v := range m {
			s, _ := v.(string)
			tok, ok := strings.CutPrefix(s, "Bearer ")
			if r := refName(tok); strings.EqualFold(h, "Authorization") && ok && r != "" {
				c.Bearer = "env:" + r
				continue
			}
			left = append(left, "header "+h)
		}
		sort.Strings(left)
	}
	typ := str("type")
	switch format {
	case "opencode-json":
		switch typ {
		case "local":
			c.Command = list("command")
			envFrom("environment")
		case "remote":
			c.URL = str("url")
			headers("headers")
		default:
			return c, left, fmt.Errorf("type %q; AFK copies local and remote servers", typ)
		}
	case "codex-toml":
		if u := str("url"); u != "" {
			c.URL = u
			if b := str("bearer_token_env_var"); b != "" {
				c.Bearer = "env:" + b
			}
			headers("http_headers")
		} else {
			c.Command = append([]string{str("command")}, list("args")...)
			c.Env = append(c.Env, list("env_vars")...)
			envFrom("env")
		}
	default: // the JSON CLIs: claude, gemini, copilot
		if typ == "sse" {
			return c, left, errors.New("an sse server; AFK copies stdio and http servers")
		}
		if u := str("url"); u != "" {
			c.URL = u
		} else if u := str("httpUrl"); u != "" {
			c.URL = u
		}
		if c.URL != "" {
			headers("headers")
		} else {
			c.Command = append([]string{str("command")}, list("args")...)
			envFrom("env")
		}
	}
	if c.URL != "" {
		u, perr := url.Parse(c.URL)
		switch {
		case strings.Contains(c.URL, "${") || strings.Contains(c.URL, "{env:"):
			return c, left, errors.New("its url uses a variable; AFK copies plain urls")
		case perr != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "":
			return c, left, errors.New("its url is not http(s)://host/...")
		case u.User != nil:
			return c, left, errors.New("its url holds a user or password")
		case u.RawQuery != "":
			return c, left, errors.New("its url has a query, which may hold a key; add it by hand")
		}
		return c, left, nil
	}
	if len(c.Command) == 0 || c.Command[0] == "" {
		return c, left, errors.New("needs a command or an http url")
	}
	sort.Strings(c.Env)
	return c, left, nil
}
