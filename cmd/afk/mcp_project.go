package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/mcp"
)

// A repository's own MCP servers live in <repo>/.mcp.json. Claude Code and
// Copilot CLI read it themselves; for the others AFK copies each server
// into the CLI's project file (gemini: .gemini/settings.json), and lists
// a file it created in .git/info/exclude. Before it copies a server AFK
// asks: this project only, or every project (added to mcp.toml and
// synced like any other). A CLI file that is committed to the repository
// is never edited.

type projectMCP struct {
	root   string
	user   mcpDeps  // mcp.toml, for "every project"
	deps   mcpDeps  // env.Project is <root>/.mcp.json, Ask is set
	native []string // CLIs that read .mcp.json themselves
	// notes says why a CLI gets no copies here.
	notes map[string]string
}

// projectMCPFor is the repository at root's servers, or nil when it has
// no .mcp.json.
func projectMCPFor(root string, he harness.Env, getenv func(string) string, user mcpDeps) *projectMCP {
	src := filepath.Join(root, mcp.ProjectFile)
	if fi, err := os.Stat(src); err != nil || fi.IsDir() {
		return nil
	}
	sum := sha256.Sum256([]byte(root))
	dir := config.PathsFor(he.Home, getenv).Dir
	p := &projectMCP{root: root, user: user, notes: map[string]string{}}
	p.deps = mcpDeps{getenv: getenv, env: mcp.Env{
		Project: src,
		State:   filepath.Join(dir, "state", "mcp-projects", hex.EncodeToString(sum[:6])+".json"),
		Ask:     true,
	}}
	r := harness.Discover(context.Background(), he, harness.Options{SkipVersion: true})
	for _, h := range r.Installed() {
		m, ok := harness.ManifestFor(h.Name)
		pf := ""
		if ok {
			pf = m.MCP.ProjectFile
		}
		switch filepath.ToSlash(filepath.Clean(pf)) {
		case ".":
			p.deps.unsupported = append(p.deps.unsupported, h.Name)
		case mcp.ProjectFile:
			p.native = append(p.native, h.Name)
		default:
			if tracked(root, pf) {
				p.notes[h.Name] = pf + " is committed to the repository; AFK won't edit it"
				p.deps.unsupported = append(p.deps.unsupported, h.Name)
				continue
			}
			p.deps.targets = append(p.deps.targets, mcp.Target{Harness: h.Name, File: filepath.Join(root, filepath.FromSlash(pf)), Format: m.MCP.Format})
		}
	}
	return p
}

// tracked reports whether git tracks rel in the repository at root.
func tracked(root, rel string) bool {
	return exec.Command("git", "-C", root, "ls-files", "--error-unmatch", "--", filepath.ToSlash(rel)).Run() == nil
}

// sync copies project-scoped servers into the CLIs' project files, and
// lists each file AFK created in .git/info/exclude.
func (p *projectMCP) sync() (*mcp.Result, error) {
	had := map[string]bool{}
	for _, t := range p.deps.targets {
		_, err := os.Stat(t.File)
		had[t.File] = err == nil
	}
	res, err := p.deps.env.Sync(p.deps.targets)
	if err != nil {
		return nil, err
	}
	var add []string
	for _, t := range p.deps.targets {
		if _, err := os.Stat(t.File); err == nil && !had[t.File] {
			rel, _ := filepath.Rel(p.root, t.File)
			add = append(add, "/"+filepath.ToSlash(rel))
		}
	}
	if err := gitExclude(p.root, add, nil); err != nil {
		return res, fmt.Errorf("synced, but couldn't update .git/info/exclude: %w", err)
	}
	return res, nil
}

// setScope records a server's scope. Global first adds it to mcp.toml.
func (p *projectMCP) setScope(server, scope string) error {
	sv, ok, err := p.deps.env.Find(server)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("no server %q AFK can copy in %s", server, mcp.ProjectFile)
	}
	if scope == mcp.ScopeGlobal {
		if err := mcp.AddToConfig(p.user.env.Config, p.user.env.Gateways, sv); err != nil {
			return err
		}
	}
	return p.deps.env.SetScope(server, scope)
}

// undecided are the project servers still waiting for a scope.
func (p *projectMCP) undecided() ([]string, error) {
	st, err := p.deps.env.Scan(p.deps.targets)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, r := range st.Rows {
		if r.Listed && r.Scope == "" {
			out = append(out, r.Name)
		}
	}
	return out, nil
}

// ask puts each undecided server to the user: p this project, g every
// project, Enter to decide later.
func (p *projectMCP) ask(in io.Reader, out io.Writer) error {
	names, err := p.undecided()
	if err != nil || len(names) == 0 {
		return err
	}
	r := bufio.NewReader(in)
	for _, n := range names {
		fmt.Fprintf(out, "Project MCP server %s: add it for p) this project only, g) every project, or Enter to decide later? ", n)
		line, err := r.ReadString('\n')
		var scope string
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "p", "project":
			scope = mcp.ScopeProject
		case "g", "global":
			scope = mcp.ScopeGlobal
		}
		if scope != "" {
			if err := p.setScope(n, scope); err != nil {
				fmt.Fprintf(out, "  %s: %v\n", n, err)
			}
		}
		if err != nil {
			break // end of input: the rest wait
		}
	}
	return nil
}

// noteUndecided says which project servers still wait for a scope.
func (p *projectMCP) noteUndecided(w io.Writer) {
	names, err := p.undecided()
	if err != nil || len(names) == 0 {
		return
	}
	fmt.Fprintf(w, "%s in %s %s for you to choose: afk mcp scope <server> project|global\n",
		strings.Join(names, ", "), mcp.ProjectFile, map[bool]string{true: "waits", false: "wait"}[len(names) == 1])
}

// projectMark is a project server's mark in one CLI.
func projectMCPMark(c mcp.Cell) string {
	switch c {
	case mcp.Ask:
		return "?"
	case mcp.Global:
		return "g"
	}
	return mcpMark(c)
}

// renderProjectMCP is the project's servers as a grid: the CLIs AFK
// copies into, then the ones that read .mcp.json themselves.
func renderProjectMCP(p *projectMCP, s *mcp.Status) string {
	var b strings.Builder
	fmt.Fprintf(&b, "\nThis project (%s):\n", tildePath(s.Config))
	if len(s.Rows) == 0 && len(s.Problems) == 0 {
		return b.String() + "No servers in " + mcp.ProjectFile + ".\n"
	}
	w := 6
	for _, r := range s.Rows {
		w = max(w, len(r.Name))
	}
	var cols []string
	for _, t := range s.Targets {
		cols = append(cols, t.Harness)
	}
	unsup := append([]string{}, p.deps.unsupported...)
	sort.Strings(unsup)
	b.WriteString(pad("SERVER", w+2) + pad("SCOPE", 10))
	for _, c := range append(append(append([]string{}, cols...), p.native...), unsup...) {
		b.WriteString(pad(c, len(c)+2))
	}
	b.WriteString("\n")
	for _, r := range s.Rows {
		scope := r.Scope
		switch {
		case !r.Listed:
			scope = "gone"
		case scope == "":
			scope = "?"
		}
		b.WriteString(pad(r.Name, w+2) + pad(scope, 10))
		for _, c := range cols {
			b.WriteString(pad(projectMCPMark(r.Cells[c]), len(c)+2))
		}
		for _, c := range p.native {
			m := "✓"
			if !r.Listed {
				m = "·"
			}
			b.WriteString(pad(m, len(c)+2))
		}
		for _, c := range unsup {
			b.WriteString(pad("–", len(c)+2))
		}
		b.WriteString("\n")
	}
	if len(p.native) > 0 {
		fmt.Fprintf(&b, "%s %s %s %s.\n", strings.Join(p.native, ", "), map[bool]string{true: "reads", false: "read"}[len(p.native) == 1], mcp.ProjectFile, map[bool]string{true: "itself", false: "themselves"}[len(p.native) == 1])
	}
	for _, h := range unsup {
		if n := p.notes[h]; n != "" {
			fmt.Fprintf(&b, "%s: %s.\n", h, n)
		}
	}
	for _, dr := range s.Drift {
		fmt.Fprintf(&b, "%s changed in %s (%s).\n", dr.Server, dr.Harness, tildePath(dr.File))
	}
	for _, pr := range s.Problems {
		fmt.Fprintln(&b, "skipped:", pr)
	}
	return b.String()
}

// projectMCPDo runs an MCP tab action on the project's servers.
func projectMCPDo(p *projectMCP, op string, args ...string) (string, error) {
	if len(args) != 2 {
		return "", fmt.Errorf("mcp %s needs a server and a second argument", op)
	}
	d := p.deps
	sv, x := args[0], args[1]
	switch op {
	case "scope":
		if err := p.setScope(sv, x); err != nil {
			return "", err
		}
		if _, err := p.sync(); err != nil {
			return "", err
		}
		if x == mcp.ScopeGlobal {
			return sv + " is in mcp.toml now. Press s to add it to every CLI.", nil
		}
		return sv + " is added for this project.", nil
	case "keep":
		if _, err := d.env.Keep(d.targets, sv, x); err != nil {
			return "", err
		}
		return fmt.Sprintf("%s in %s's project file is now yours; AFK won't change it again.", sv, x), nil
	case "restore":
		if _, err := d.env.Restore(d.targets, sv, x); err != nil {
			return "", err
		}
		return fmt.Sprintf("Wrote the project's %s back into %s (the file is backed up).", sv, x), nil
	case "enable", "disable":
		if err := d.env.SetEnabled(sv, x, op == "enable"); err != nil {
			return "", err
		}
		return fmt.Sprintf("%s %sd for %s in this project. Press s to apply it.", sv, op, x), nil
	}
	return "", fmt.Errorf("unknown project mcp action %q", op)
}
