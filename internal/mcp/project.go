package mcp

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

// A repository can keep its own MCP servers in .mcp.json, the file Claude
// Code and Copilot CLI read themselves. AFK copies each server into the
// other CLIs' project files, or into mcp.toml for every project, as the
// user chooses. An Env with Project set works on those servers.

// ProjectFile is where a repository keeps its own servers.
const ProjectFile = ".mcp.json"

// The scopes a project server can be given.
const (
	ScopeProject = "project" // copied into this repository's CLI files
	ScopeGlobal  = "global"  // added to mcp.toml, for every project
)

// Cells of project servers.
const (
	Ask    Cell = "ask"    // waiting for the user to choose a scope
	Global Cell = "global" // in mcp.toml, synced from there
)

var reRef = regexp.MustCompile(`^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$`)

// LoadProject reads a repository's .mcp.json. A server AFK can't copy
// without writing a value it must not (a literal env value or header)
// is left out, with the reason in skipped. A missing file is no servers.
func LoadProject(path string) (servers []Server, skipped map[string]string, err error) {
	skipped = map[string]string{}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, skipped, nil
	}
	if err != nil {
		return nil, skipped, err
	}
	var f struct {
		Servers map[string]projectEntry `json:"mcpServers"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, skipped, fmt.Errorf("%s: %w", path, err)
	}
	for name, pe := range f.Servers {
		s, err := pe.server(name)
		if err != nil {
			skipped[name] = err.Error()
			continue
		}
		servers = append(servers, s)
	}
	sort.Slice(servers, func(i, j int) bool { return servers[i].Name < servers[j].Name })
	return servers, skipped, nil
}

type projectEntry struct {
	Type    string            `json:"type"`
	Command string            `json:"command"`
	Args    []string          `json:"args"`
	Env     map[string]string `json:"env"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}

// server is the entry as a Server, when AFK can copy it by variable names
// alone.
func (pe projectEntry) server(name string) (Server, error) {
	c := ServerConfig{Name: name}
	switch {
	case pe.Type == "sse":
		return Server{}, errors.New("an sse server; AFK copies stdio and http servers")
	case pe.Command != "" && (pe.Type == "" || pe.Type == "stdio"):
		c.Command = append([]string{pe.Command}, pe.Args...)
		for k, v := range pe.Env {
			m := reRef.FindStringSubmatch(v)
			if m == nil || m[1] != k {
				return Server{}, fmt.Errorf("env %s is set to a value; AFK only copies %s = \"${%s}\"", k, k, k)
			}
			c.Env = append(c.Env, k)
		}
		sort.Strings(c.Env)
	case pe.URL != "" && (pe.Type == "" || pe.Type == "http"):
		if strings.Contains(pe.URL, "${") {
			return Server{}, errors.New("its url uses a variable; AFK copies plain urls")
		}
		c.URL = pe.URL
		for k, v := range pe.Headers {
			tok, ok := strings.CutPrefix(v, "Bearer ")
			m := reRef.FindStringSubmatch(tok)
			if !strings.EqualFold(k, "Authorization") || !ok || m == nil {
				return Server{}, fmt.Errorf("header %s; AFK only copies Authorization: Bearer ${NAME}", k)
			}
			c.Bearer = "env:" + m[1]
		}
	default:
		return Server{}, errors.New("needs a command or an http url")
	}
	return resolve(c, "", nil)
}

// servers is the list this Env syncs: mcp.toml, or the project's
// .mcp.json with the servers it can't copy as problems.
func (e Env) servers() ([]Server, []string, error) {
	if e.Project == "" {
		s, err := Load(e.Config, e.Gateways)
		return s, nil, err
	}
	s, skipped, err := LoadProject(e.Project)
	var probs []string
	for n, why := range skipped {
		probs = append(probs, n+" in "+ProjectFile+": "+why)
	}
	sort.Strings(probs)
	return s, probs, err
}

// SetScope records where a project server goes: ScopeProject or
// ScopeGlobal ("" asks again).
func (e Env) SetScope(server, scope string) error {
	if scope != ScopeProject && scope != ScopeGlobal && scope != "" {
		return fmt.Errorf("scope must be %s or %s", ScopeProject, ScopeGlobal)
	}
	l, err := e.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	st, err := e.load()
	if err != nil {
		return err
	}
	if scope == "" {
		delete(st.Scope, server)
	} else {
		st.Scope[server] = scope
	}
	return e.save(st)
}

// AddToConfig appends a server to mcp.toml, keeping what is there. A
// server of that name already in mcp.toml is left as it is: the same one
// is no change, a different one is an error.
func AddToConfig(config string, gateways map[string]string, s Server) error {
	have, err := Load(config, gateways)
	if err != nil {
		return err
	}
	for _, h := range have {
		if h.Name != s.Name {
			continue
		}
		if h.Kind == s.Kind && h.URL == s.URL && h.Command == s.Command && canon(strs(h.Args)) == canon(strs(s.Args)) &&
			canon(strs(h.Env)) == canon(strs(s.Env)) && h.BearerEnv == s.BearerEnv {
			return nil
		}
		return fmt.Errorf("mcp.toml already has a different server named %s", s.Name)
	}
	b, err := os.ReadFile(config)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	var w strings.Builder
	w.Write(b)
	if len(b) > 0 && !strings.HasSuffix(string(b), "\n") {
		w.WriteString("\n")
	}
	if len(b) > 0 {
		w.WriteString("\n")
	}
	fmt.Fprintf(&w, "[[server]]\nname = %s\n", tomlString(s.Name))
	if s.Kind == "stdio" {
		parts := []string{tomlString(s.Command)}
		for _, a := range s.Args {
			parts = append(parts, tomlString(a))
		}
		fmt.Fprintf(&w, "command = [%s]\n", strings.Join(parts, ", "))
		if len(s.Env) > 0 {
			var names []string
			for _, n := range s.Env {
				names = append(names, tomlString(n))
			}
			fmt.Fprintf(&w, "env = [%s]\n", strings.Join(names, ", "))
		}
	} else {
		fmt.Fprintf(&w, "url = %s\n", tomlString(s.URL))
		if s.BearerEnv != "" {
			fmt.Fprintf(&w, "bearer = %s\n", tomlString("env:"+s.BearerEnv))
		}
	}
	out := []byte(w.String())
	if err := statefile.WriteFile(config, out); err != nil {
		return err
	}
	if _, err := Load(config, gateways); err != nil {
		_ = statefile.WriteFile(config, b) // put it back as it was
		return err
	}
	return nil
}

// Find is one of this Env's servers by name.
func (e Env) Find(name string) (Server, bool, error) {
	s, _, err := e.servers()
	if err != nil {
		return Server{}, false, err
	}
	for _, x := range s {
		if x.Name == name {
			return x, true, nil
		}
	}
	return Server{}, false, nil
}
