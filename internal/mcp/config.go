// Package mcp keeps one list of MCP servers (~/.config/afk/mcp.toml) and
// writes it into each agent CLI's own MCP config, in that CLI's format.
//
// It works the way the skills sync does: every change is planned, made
// under a lock, backed up, written beside the old file and renamed into
// place, verified, and rolled back if any step fails. AFK only changes
// entries it wrote itself. A server you added to a CLI by hand is never
// touched, and an entry AFK wrote that you then edited is left alone until
// you say which copy wins.
//
// Secrets never pass through AFK: a server's bearer token and environment
// are names of environment variables, written into each CLI's config as
// that CLI's own variable reference (${NAME}, {env:NAME}, ...).
package mcp

import (
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// File is mcp.toml.
type File struct {
	Defaults struct {
		Via string `toml:"via"`
	} `toml:"defaults"`
	Servers []ServerConfig `toml:"server"`
}

// ServerConfig is one [[server]] as written.
type ServerConfig struct {
	Name string `toml:"name"`
	// Via is "stdio", "http", or the id of a [gateway.<id>] in
	// config.toml whose MCP endpoint serves it.
	Via string `toml:"via"`
	// URL is the server's address (via = "http"). Through a gateway it
	// may be left out: the gateway's URL plus Path.
	URL  string `toml:"url"`
	Path string `toml:"path"`
	// Command runs a stdio server: program and arguments.
	Command []string `toml:"command"`
	// Env names environment variables the server needs. Each CLI is told
	// to pass them through; their values are never read or written.
	Env []string `toml:"env"`
	// Bearer is "env:NAME": the variable holding the token sent as
	// "Authorization: Bearer ..." to an HTTP server.
	Bearer string `toml:"bearer"`
	// Harnesses is "all" (the default) or a list of CLI names.
	Harnesses any `toml:"harnesses"`
}

// Server is a server ready to write.
type Server struct {
	Name      string   `json:"name"`
	Kind      string   `json:"kind"` // http or stdio
	Via       string   `json:"via"`  // http, stdio or a gateway id
	URL       string   `json:"url,omitempty"`
	Command   string   `json:"command,omitempty"`
	Args      []string `json:"args,omitempty"`
	Env       []string `json:"env,omitempty"`
	BearerEnv string   `json:"bearer_env,omitempty"`
	// All is true for harnesses = "all"; else Harnesses lists them.
	All       bool     `json:"all"`
	Harnesses []string `json:"harnesses,omitempty"`
}

// For reports whether mcp.toml gives the server to a CLI.
func (s Server) For(harness string) bool {
	if s.All {
		return true
	}
	for _, h := range s.Harnesses {
		if h == harness {
			return true
		}
	}
	return false
}

var (
	reName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)
	reVar  = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
)

// ValidName reports whether s can name a server in every CLI's config.
func ValidName(s string) bool { return reName.MatchString(s) }

// Load reads mcp.toml. A missing file is an empty list. gateways maps a
// gateway id to its base URL, for servers reached through one.
func Load(path string, gateways map[string]string) ([]Server, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var f File
	if err := toml.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	var out []Server
	seen := map[string]bool{}
	for i, c := range f.Servers {
		s, err := resolve(c, f.Defaults.Via, gateways)
		if err != nil {
			name := c.Name
			if name == "" {
				name = fmt.Sprintf("#%d", i+1)
			}
			return nil, fmt.Errorf("%s: server %s: %w", path, name, err)
		}
		if seen[s.Name] {
			return nil, fmt.Errorf("%s: server %s is listed twice", path, s.Name)
		}
		seen[s.Name] = true
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func resolve(c ServerConfig, defVia string, gateways map[string]string) (Server, error) {
	s := Server{Name: c.Name, Via: c.Via, Env: c.Env}
	if !ValidName(c.Name) {
		return s, fmt.Errorf("name %q must be lowercase letters, digits, - and _", c.Name)
	}
	for _, e := range c.Env {
		if !reVar.MatchString(e) {
			return s, fmt.Errorf("env %q is not a variable name (give names, never values)", e)
		}
	}
	if s.Via == "" {
		switch {
		case len(c.Command) > 0:
			s.Via = "stdio"
		case c.URL != "":
			s.Via = "http"
		default:
			s.Via = defVia
		}
	}
	switch s.Via {
	case "":
		return s, errors.New("needs a command, a url, or via = a gateway")
	case "stdio":
		if len(c.Command) == 0 || strings.TrimSpace(c.Command[0]) == "" {
			return s, errors.New("a stdio server needs command = [program, args...]")
		}
		s.Kind, s.Command, s.Args = "stdio", c.Command[0], c.Command[1:]
	default:
		s.Kind = "http"
		u := c.URL
		if s.Via != "http" {
			base, ok := gateways[s.Via]
			if !ok {
				return s, fmt.Errorf("via %q is not stdio, http or a gateway in config.toml", s.Via)
			}
			if u == "" {
				p := c.Path
				if p == "" {
					p = "/mcp"
				}
				u = strings.TrimRight(base, "/") + "/" + strings.TrimLeft(p, "/")
			}
		}
		pu, err := url.Parse(u)
		if err != nil || (pu.Scheme != "http" && pu.Scheme != "https") || pu.Host == "" {
			return s, fmt.Errorf("url %q must be http(s)://host/...", u)
		}
		if pu.User != nil {
			return s, errors.New("the url must not hold a user or password; use bearer = \"env:NAME\"")
		}
		s.URL = u
	}
	if s.Kind == "http" && len(c.Env) > 0 {
		return s, errors.New("env is for stdio servers; an http server takes bearer")
	}
	if c.Bearer != "" {
		name, ok := strings.CutPrefix(c.Bearer, "env:")
		if !ok || !reVar.MatchString(name) {
			return s, errors.New(`bearer must be "env:NAME", the variable that holds the token (never the token)`)
		}
		if s.Kind != "http" {
			return s, errors.New("bearer is for http servers")
		}
		s.BearerEnv = name
	}
	switch h := c.Harnesses.(type) {
	case nil:
		s.All = true
	case string:
		if h != "all" && h != "all-supported" {
			return s, fmt.Errorf("harnesses = %q: use \"all\" or a list", h)
		}
		s.All = true
	case []any:
		for _, x := range h {
			n, ok := x.(string)
			if !ok || n == "" {
				return s, errors.New("harnesses must be a list of CLI names")
			}
			s.Harnesses = append(s.Harnesses, n)
		}
	default:
		return s, errors.New(`harnesses must be "all" or a list of CLI names`)
	}
	return s, nil
}
