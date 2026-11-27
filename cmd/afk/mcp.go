package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/x/term"
	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/mcp"
)

const mcpHelp = `Usage: afk mcp [status] [--json]
       afk mcp sync [--dry-run] [--json]
       afk mcp test <server> [--json]
       afk mcp keep|restore <server> <cli> [--project]
       afk mcp enable|disable <server> <cli> [--project]
       afk mcp scope <server> project|global
       afk mcp edit|path

Keeps one list of MCP servers in ~/.config/afk/mcp.toml and writes each
into every installed CLI's own MCP config, in that CLI's format.

  status    each server in each CLI; nothing is changed
  sync      write new and changed servers into the CLIs (--dry-run shows the plan)
  test      connect to a server and list its tools (tools/list)
  keep      leave a CLI's edited entry as its own; AFK stops managing it
  restore   write AFK's entry back over a CLI's edited one
  enable    turn a server on or off for one CLI here (the next sync applies it)
  scope     add a server from this repository's .mcp.json for this project
            only, or for every project (adds it to mcp.toml)
  edit      open mcp.toml in your editor (a commented template when new)
  path      print where mcp.toml is

AFK only changes entries it wrote. A server you added to a CLI yourself is
shown as a conflict and left alone, and an edit made in a CLI is never
overwritten without "restore". Each file is backed up under
~/.config/afk/state/backups/mcp first, and every file is put back if any
write fails. Tokens never pass through AFK: mcp.toml names the variable
(bearer = "env:NAME"), and each CLI is told to read that variable.

A repository's own servers live in its .mcp.json, which Claude Code and
Copilot CLI read themselves. For the other CLIs AFK copies each server into
the CLI's project file (gemini: .gemini/settings.json) and lists a file it
created in .git/info/exclude; a file committed to the repository is never
edited. AFK asks first, for each server: this project only, or every
project. sync asks in a terminal; elsewhere use scope. --project makes
keep, restore, enable and disable act on these servers. A server whose env
or headers hold values rather than ${NAME} references is not copied.
`

type mcpDeps struct {
	env         mcp.Env
	targets     []mcp.Target
	unsupported []string
	getenv      func(string) string
	// project is this repository's .mcp.json (nil when it has none).
	project func() *projectMCP
	// interactive is whether sync may ask about project servers.
	interactive bool
	in          io.Reader
}

func (d mcpDeps) stdin() io.Reader {
	if d.in != nil {
		return d.in
	}
	return os.Stdin
}

// mcpTargets is every installed CLI with an MCP config AFK knows, and the
// installed CLIs without one.
func mcpTargets(he harness.Env) (targets []mcp.Target, unsupported []string) {
	r := harness.Discover(context.Background(), he, harness.Options{SkipVersion: true})
	for _, h := range r.Installed() {
		m, ok := harness.ManifestFor(h.Name)
		file := ""
		if ok {
			file = m.MCPFile(he)
		}
		if file == "" {
			unsupported = append(unsupported, h.Name)
			continue
		}
		targets = append(targets, mcp.Target{Harness: h.Name, File: file, Format: m.MCP.Format})
	}
	return targets, unsupported
}

// mcpGateways is each config.toml gateway's MCP endpoint.
func mcpGateways(s config.Settings) map[string]string {
	out := map[string]string{}
	for name, g := range s.Gateways {
		switch {
		case g.MCP != "":
			out[name] = g.MCP
		case g.URL != "":
			if u, err := url.Parse(g.URL); err == nil {
				out[name] = (&url.URL{Scheme: u.Scheme, Host: u.Host, Path: "/mcp"}).String()
			}
		}
	}
	return out
}

func mcpEnvFor(home string, getenv func(string) string, s config.Settings) mcp.Env {
	dir := config.PathsFor(home, getenv).Dir
	return mcp.Env{Config: filepath.Join(dir, "mcp.toml"), State: filepath.Join(dir, "state", "mcp.json"), Gateways: mcpGateways(s)}
}

func hostMCP() (mcpDeps, error) {
	he := harness.HostEnv()
	cwd, _ := os.Getwd()
	s, err := config.Resolve(config.Env{Home: he.Home, Getenv: os.Getenv, Repo: cwd})
	if err != nil {
		return mcpDeps{}, err
	}
	t, u := mcpTargets(he)
	d := mcpDeps{env: mcpEnvFor(he.Home, os.Getenv, s), targets: t, unsupported: u, getenv: os.Getenv,
		interactive: term.IsTerminal(os.Stdin.Fd()) && term.IsTerminal(os.Stdout.Fd())}
	user := d
	d.project = func() *projectMCP { return projectMCPFor(repoRoot(cwd), he, os.Getenv, user) }
	return d, nil
}

func mcpCmd(argv []string, stdout, stderr io.Writer) int {
	d, err := hostMCP()
	if err != nil {
		fmt.Fprintln(stderr, "afk mcp:", err)
		return 1
	}
	return runMCP(d, argv, stdout, stderr)
}

func runMCP(d mcpDeps, argv []string, stdout, stderr io.Writer) int {
	sub := "status"
	if len(argv) > 0 && !strings.HasPrefix(argv[0], "-") {
		sub, argv = argv[0], argv[1:]
	}
	asJSON, dry, inProject := false, false, false
	var args []string
	for _, a := range argv {
		switch a {
		case "--json":
			asJSON = true
		case "--project":
			inProject = true
		case "--dry-run", "-n":
			dry = true
		case "-h", "--help":
			fmt.Fprint(stdout, mcpHelp)
			return 0
		default:
			if strings.HasPrefix(a, "-") {
				fmt.Fprintf(stderr, "afk mcp: unknown flag %q\n\n%s", a, mcpHelp)
				return 2
			}
			args = append(args, a)
		}
	}
	fail := func(err error) int {
		fmt.Fprintln(stderr, "afk mcp:", err)
		return 1
	}
	need := func(n int, usage string) bool {
		if len(args) != n {
			fmt.Fprintf(stderr, "afk mcp: usage: afk mcp %s\n", usage)
			return false
		}
		return true
	}
	var proj *projectMCP
	if d.project != nil && (sub == "status" || sub == "list" || sub == "ls" || sub == "sync" || sub == "scope" || inProject) {
		proj = d.project()
	}
	if inProject {
		// keep, restore, enable and disable on the repository's own
		// servers rather than mcp.toml's.
		switch sub {
		case "keep", "restore", "enable", "disable":
		default:
			fmt.Fprintf(stderr, "afk mcp: --project goes with keep, restore, enable or disable\n")
			return 2
		}
		if proj == nil {
			return fail(fmt.Errorf("this repository has no %s", mcp.ProjectFile))
		}
		d.env, d.targets = proj.deps.env, proj.deps.targets
	}
	switch sub {
	case "help":
		fmt.Fprint(stdout, mcpHelp)
		return 0
	case "scope":
		if !need(2, "scope <server> project|global") {
			return 2
		}
		if proj == nil {
			return fail(fmt.Errorf("this repository has no %s", mcp.ProjectFile))
		}
		if err := proj.setScope(args[0], args[1]); err != nil {
			return fail(err)
		}
		if _, err := proj.sync(); err != nil {
			return fail(err)
		}
		if args[1] == mcp.ScopeGlobal {
			fmt.Fprintf(stdout, "%s is in %s now. Run afk mcp sync to add it to every CLI.\n", args[0], tildePath(d.env.Config))
			return 0
		}
		fmt.Fprintf(stdout, "%s is added for this project.\n", args[0])
		return 0
	case "path":
		fmt.Fprintln(stdout, d.env.Config)
		return 0
	case "edit":
		if _, err := os.Stat(d.env.Config); os.IsNotExist(err) {
			if err := os.MkdirAll(filepath.Dir(d.env.Config), 0o755); err != nil {
				return fail(err)
			}
			if err := os.WriteFile(d.env.Config, []byte(mcpTemplate), 0o644); err != nil {
				return fail(err)
			}
		}
		c := editorCmd(d.env.Config)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := c.Run(); err != nil {
			return fail(err)
		}
		if _, err := mcp.Load(d.env.Config, d.env.Gateways); err != nil {
			fmt.Fprintln(stderr, "afk mcp:", err)
			fmt.Fprint(stdout, "Fix it with afk mcp edit. Press Enter to go back. ")
			_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
			return 1
		}
		return 0
	case "status", "list", "ls":
		if !need(0, "status [--json]") {
			return 2
		}
		s, err := d.env.Scan(d.targets)
		if err != nil {
			return fail(err)
		}
		var ps *mcp.Status
		if proj != nil {
			if ps, err = proj.deps.env.Scan(proj.deps.targets); err != nil {
				return fail(err)
			}
		}
		if asJSON {
			return writeJSON(stdout, stderr, struct {
				Schema string `json:"schema"`
				*mcp.Status
				Unsupported []string    `json:"unsupported"`
				Project     *mcp.Status `json:"project,omitempty"`
			}{"afk-mcp/1", s, nonNil(d.unsupported), ps})
		}
		fmt.Fprint(stdout, renderMCP(d, s))
		if ps != nil {
			fmt.Fprint(stdout, renderProjectMCP(proj, ps))
			proj.noteUndecided(stdout)
		}
		return 0
	case "sync":
		if !need(0, "sync [--dry-run] [--json]") {
			return 2
		}
		if dry {
			s, err := d.env.Scan(d.targets)
			if err != nil {
				return fail(err)
			}
			if proj != nil {
				ps, err := proj.deps.env.Scan(proj.deps.targets)
				if err != nil {
					return fail(err)
				}
				s.Actions = append(s.Actions, ps.Actions...)
			}
			if asJSON {
				return writeJSON(stdout, stderr, map[string]any{"schema": "afk-mcp-sync/1", "dry_run": true, "actions": s.Actions})
			}
			if len(s.Actions) == 0 {
				fmt.Fprintln(stdout, "Nothing to sync.")
			}
			for _, a := range s.Actions {
				fmt.Fprintf(stdout, "would %-6s %s in %s (%s)\n", a.Kind, a.Server, a.Harness, tildePath(a.File))
			}
			return 0
		}
		// Ask first: a server given to every project joins mcp.toml, and
		// this sync then writes it.
		if proj != nil && d.interactive && !asJSON {
			if err := proj.ask(d.stdin(), stdout); err != nil {
				return fail(err)
			}
		}
		res, err := d.env.Sync(d.targets)
		if err != nil {
			return fail(err)
		}
		if proj != nil {
			pres, err := proj.sync()
			if err != nil {
				return fail(err)
			}
			res.Done = append(res.Done, pres.Done...)
		}
		if asJSON {
			return writeJSON(stdout, stderr, map[string]any{"schema": "afk-mcp-sync/1", "done": res.Done, "backup": res.Backup})
		}
		printMCPResult(stdout, res, "Nothing to sync.")
		if proj != nil {
			proj.noteUndecided(stdout)
		}
		return 0
	case "test":
		if !need(1, "test <server> [--json]") {
			return 2
		}
		s, env, ok, err := findMCPServer(d, args[0])
		if err != nil {
			return fail(err)
		}
		if ok {
			tools, err := mcp.ListTools(context.Background(), s, d.getenv)
			rec := mcp.Tested{OK: err == nil, Tools: len(tools), At: time.Now().UTC()}
			if err != nil {
				rec.Error = err.Error()
			}
			_ = env.Record(s.Name, rec)
			if asJSON {
				code := writeJSON(stdout, stderr, map[string]any{"schema": "afk-mcp-test/1", "server": s.Name, "ok": rec.OK, "tools": nonNilT(tools), "error": rec.Error})
				if err != nil {
					return 1
				}
				return code
			}
			if err != nil {
				return fail(fmt.Errorf("%s: %w", s.Name, err))
			}
			fmt.Fprintf(stdout, "%s is up: %s.\n", s.Name, plural(len(tools), "tool"))
			for _, t := range tools {
				fmt.Fprintln(stdout, "  "+t.Name)
			}
			return 0
		}
		return fail(fmt.Errorf("no server %q in %s", args[0], tildePath(d.env.Config)))
	case "keep", "restore":
		if !need(2, sub+" <server> <cli>") {
			return 2
		}
		var res *mcp.Result
		var err error
		if sub == "keep" {
			res, err = d.env.Keep(d.targets, args[0], args[1])
		} else {
			res, err = d.env.Restore(d.targets, args[0], args[1])
		}
		if err != nil {
			return fail(err)
		}
		if asJSON {
			return writeJSON(stdout, stderr, res)
		}
		if sub == "keep" {
			fmt.Fprintf(stdout, "%s in %s is now yours; AFK won't change it again.\n", args[0], args[1])
			return 0
		}
		printMCPResult(stdout, res, "")
		return 0
	case "enable", "disable":
		if !need(2, sub+" <server> <cli>") {
			return 2
		}
		if _, ok := findTarget(d.targets, args[1]); !ok {
			return fail(fmt.Errorf("%s is not an installed CLI with an MCP config AFK knows", args[1]))
		}
		if err := d.env.SetEnabled(args[0], args[1], sub == "enable"); err != nil {
			return fail(err)
		}
		fmt.Fprintf(stdout, "%s %sd for %s. Run afk mcp sync to apply it.\n", args[0], sub, args[1])
		return 0
	}
	fmt.Fprintf(stderr, "afk mcp: unknown command %q\n\n%s", sub, mcpHelp)
	return 2
}

func findTarget(ts []mcp.Target, h string) (mcp.Target, bool) {
	for _, t := range ts {
		if t.Harness == h {
			return t, true
		}
	}
	return mcp.Target{}, false
}

func nonNilT(t []mcp.Tool) []mcp.Tool {
	if t == nil {
		return []mcp.Tool{}
	}
	return t
}

func printMCPResult(w io.Writer, res *mcp.Result, none string) {
	if len(res.Done) == 0 && none != "" {
		fmt.Fprintln(w, none)
	}
	for _, a := range res.Done {
		fmt.Fprintf(w, "%-7s %s in %s (%s)\n", a.Kind, a.Server, a.Harness, tildePath(a.File))
	}
	if res.Backup != "" {
		fmt.Fprintln(w, "Backup:", res.Backup)
	}
}

func mcpMark(c mcp.Cell) string {
	switch c {
	case mcp.Synced:
		return "✓"
	case mcp.Drifted:
		return "↻"
	case mcp.Pending:
		return "+"
	case mcp.Removing, mcp.Orphan:
		return "-"
	case mcp.Conflict:
		return "!"
	case mcp.Unsupported:
		return "–"
	case mcp.Broken:
		return "✗"
	}
	return "·"
}

const mcpLegend = "✓ in sync  ↻ changed in that CLI  · not enabled  – not supported\n+ next sync adds it  - next sync removes it  ! your own entry, left alone  ✗ file unreadable"

func renderMCP(d mcpDeps, s *mcp.Status) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s · %s\n", plural(len(s.Servers), "server"), tildePath(s.Config))
	if len(s.Rows) == 0 {
		fmt.Fprintf(&b, "\nNo servers yet. Add one to %s:\n\n  [[server]]\n  name = \"github\"\n  url = \"https://example.com/mcp\"\n  bearer = \"env:GITHUB_MCP_TOKEN\"\n", tildePath(s.Config))
		return b.String()
	}
	cols := make([]string, len(s.Targets))
	for i, t := range s.Targets {
		cols[i] = t.Harness
	}
	unsup := append([]string{}, d.unsupported...)
	sort.Strings(unsup)
	via := map[string]string{}
	for _, sv := range s.Servers {
		via[sv.Name] = sv.Via
	}
	w := 6
	for _, r := range s.Rows {
		w = max(w, len(r.Name))
	}
	b.WriteString("\n" + pad("SERVER", w+2) + pad("VIA", 12))
	for _, c := range append(cols, unsup...) {
		b.WriteString(pad(c, len(c)+2))
	}
	b.WriteString("STATUS\n")
	for _, r := range s.Rows {
		v := via[r.Name]
		if !r.Listed {
			v = "(removed)"
		}
		b.WriteString(pad(r.Name, w+2) + pad(v, 12))
		for _, c := range cols {
			b.WriteString(pad(mcpMark(r.Cells[c]), len(c)+2))
		}
		for _, c := range unsup {
			b.WriteString(pad("–", len(c)+2))
		}
		b.WriteString(testedText(s.Tested[r.Name], time.Now()) + "\n")
	}
	b.WriteString("\n" + mcpLegend + "\n")
	for _, r := range s.Rows {
		for _, c := range cols {
			if n := r.Notes[c]; n != "" && r.Cells[c] != mcp.Conflict {
				fmt.Fprintf(&b, "%s in %s: %s\n", r.Name, c, n)
			}
		}
	}
	for _, dr := range s.Drift {
		fmt.Fprintf(&b, "\n%s changed in %s (%s). afk mcp keep|restore %s %s\n", dr.Server, dr.Harness, tildePath(dr.File), dr.Server, dr.Harness)
	}
	for _, p := range s.Problems {
		fmt.Fprintln(&b, "problem:", p)
	}
	if n := len(s.Actions); n > 0 {
		fmt.Fprintf(&b, "\n%s waiting. Run afk mcp sync.\n", plural(n, "change"))
	}
	return b.String()
}

// testedText is a server's last test, as "up · 21 tools · 2h ago".
func testedText(t mcp.Tested, now time.Time) string {
	if t.At.IsZero() {
		return "untested"
	}
	when := ago(now.Sub(t.At))
	if !t.OK {
		return "down · " + when
	}
	return fmt.Sprintf("up · %s · %s", plural(t.Tools, "tool"), when)
}

func ago(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d/time.Minute))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d/time.Hour))
	}
	return fmt.Sprintf("%dd ago", int(d/(24*time.Hour)))
}

const mcpTemplate = `# MCP servers AFK writes into each agent CLI (afk mcp sync).
# Tokens never go in this file: bearer names the variable that holds one.
#
# [[server]]
# name = "github"
# url = "https://api.githubcopilot.com/mcp/"
# bearer = "env:GITHUB_MCP_TOKEN"
#
# [[server]]
# name = "tools"
# via = "homelab"          # a [gateway.homelab] in config.toml: its MCP endpoint
#
# [[server]]
# name = "playwright"
# command = ["npx", "@playwright/mcp@latest"]
# harnesses = ["claude", "codex"]   # default: all
`

// testMCPServer lists a server's tools and records the result as its last
// test, for the tab's t and ↵.
func testMCPServer(ctx context.Context, d mcpDeps, name string) ([]mcp.Tool, error) {
	sv, env, ok, err := findMCPServer(d, name)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("no server %q in mcp.toml or %s", name, mcp.ProjectFile)
	}
	tools, err := mcp.ListTools(ctx, sv, d.getenv)
	rec := mcp.Tested{OK: err == nil, Tools: len(tools), At: time.Now().UTC()}
	if err != nil {
		rec.Error = err.Error()
	}
	_ = env.Record(sv.Name, rec)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", sv.Name, err)
	}
	return tools, nil
}

// findMCPServer is a server by name from mcp.toml, else from the
// repository's .mcp.json, with the Env its test result is recorded in.
func findMCPServer(d mcpDeps, name string) (mcp.Server, mcp.Env, bool, error) {
	if sv, ok, err := d.env.Find(name); err != nil || ok {
		return sv, d.env, ok, err
	}
	if d.project != nil {
		if p := d.project(); p != nil {
			sv, ok, err := p.deps.env.Find(name)
			return sv, p.deps.env, ok, err
		}
	}
	return mcp.Server{}, d.env, false, nil
}
