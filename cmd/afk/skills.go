package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/charmbracelet/x/term"
	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/skills"
)

const skillsHelp = `Usage: afk skills [status] [--json]
       afk skills sync [--dry-run] [--json]
       afk skills diff <skill> <cli>
       afk skills keep <skill> <cli>
       afk skills restore <skill> <cli>
       afk skills enable|disable <skill> <cli>
       afk skills new <name> [description] [--edit]
       afk skills edit <name>
       afk skills scope <skill> project|global
       (any of the above with --project: this repository's .agents/skills)

Keeps one copy of every skill in ~/.config/afk/skills/<name>/SKILL.md and
copies it into each installed CLI's own skills folder.

  status    each skill in each CLI; nothing is changed
  sync      copy new and changed skills into the CLIs (--dry-run shows the plan)
  diff      how a CLI's edited copy differs from central
  keep      make a CLI's edited copy the central one
  restore   put the central copy back over a CLI's edited one
  enable    turn a skill on or off for one CLI (the next sync applies it)
  new       start a central skill and print its SKILL.md path (--edit opens it)
  scope     install a project skill for this project only, or for every
            project (copies it into ~/.config/afk/skills)

A repository's own skills live in .agents/skills. Most CLIs read that
folder themselves; for the others (claude) AFK copies each skill into
the CLI's project folder and lists the copy in .git/info/exclude. AFK
asks before it installs a project skill: sync asks in a terminal, and
the Skills tab shows ? until you choose.

AFK only touches the copies it wrote. A skill you made yourself with the
same name is shown as a conflict and left alone, and an edit inside a CLI
is never overwritten without "restore". Every change is backed up under
~/.config/afk/state/backups/skills first and rolled back if it fails.
`

// skillsEnvFor is where the central skills and the state file live.
func skillsEnvFor(home string, getenv func(string) string) skills.Env {
	dir := config.PathsFor(home, getenv).Dir
	return skills.Env{Central: filepath.Join(dir, "skills"), State: filepath.Join(dir, "state", "skills.json")}
}

// skillTargets is every installed CLI with a skills folder, and the
// installed CLIs AFK can't sync skills into.
func skillTargets(he harness.Env) (targets []skills.Target, unsupported []string) {
	r := harness.Discover(context.Background(), he, harness.Options{SkipVersion: true})
	for _, h := range r.Installed() {
		m, ok := harness.ManifestFor(h.Name)
		dir := ""
		if ok {
			dir = m.SkillsDir(he)
		}
		if dir == "" {
			unsupported = append(unsupported, h.Name)
			continue
		}
		targets = append(targets, skills.Target{Harness: h.Name, Dir: dir})
	}
	return targets, unsupported
}

type skillsDeps struct {
	env         skills.Env
	targets     []skills.Target
	unsupported []string
	in          io.Reader // stdin (tests)
	// project is this repository's skills (nil when it has none).
	project func() *projectSkills
	// interactive is whether sync may ask about project skills.
	interactive bool
}

func (d skillsDeps) stdin() io.Reader {
	if d.in != nil {
		return d.in
	}
	return os.Stdin
}

func hostSkills() skillsDeps {
	he := harness.HostEnv()
	t, u := skillTargets(he)
	return skillsDeps{env: skillsEnvFor(he.Home, os.Getenv), targets: t, unsupported: u,
		interactive: term.IsTerminal(os.Stdin.Fd()) && term.IsTerminal(os.Stdout.Fd()),
		project: func() *projectSkills {
			cwd, err := os.Getwd()
			if err != nil {
				return nil
			}
			return projectSkillsFor(repoRoot(cwd), he, os.Getenv)
		}}
}

func skillsCmd(argv []string, stdout, stderr io.Writer) int {
	return runSkills(hostSkills(), argv, stdout, stderr)
}

func runSkills(d skillsDeps, argv []string, stdout, stderr io.Writer) int {
	sub := "status"
	if len(argv) > 0 && !strings.HasPrefix(argv[0], "-") {
		sub, argv = argv[0], argv[1:]
	}
	asJSON, dry, wait, edit, project := false, false, false, false, false
	var args []string
	for _, a := range argv {
		switch a {
		case "--json":
			asJSON = true
		case "--dry-run", "-n":
			dry = true
		case "--wait":
			wait = true
		case "--edit":
			edit = true
		case "--project":
			project = true
		case "-h", "--help":
			fmt.Fprint(stdout, skillsHelp)
			return 0
		default:
			if strings.HasPrefix(a, "-") {
				fmt.Fprintf(stderr, "afk skills: unknown flag %q\n\n%s", a, skillsHelp)
				return 2
			}
			args = append(args, a)
		}
	}
	fail := func(err error) int {
		fmt.Fprintln(stderr, "afk skills:", err)
		return 1
	}
	need := func(n int, usage string) bool {
		if len(args) != n {
			fmt.Fprintf(stderr, "afk skills: usage: afk skills %s\n", usage)
			return false
		}
		return true
	}
	// --project (and scope) work on this repository's skills instead.
	var proj *projectSkills
	if d.project != nil {
		proj = d.project()
	}
	if project || sub == "scope" {
		if proj == nil {
			return fail(fmt.Errorf("this repository has no %s folder", projectSkillsDir))
		}
		if sub == "new" {
			return fail(fmt.Errorf("make a project skill as a folder in %s", projectSkillsDir))
		}
		in := d.in
		d = proj.deps
		d.in = in
	} else {
		proj = nil // plain commands only look at the project in status and sync
		if sub == "status" || sub == "list" || sub == "ls" || sub == "sync" {
			if d.project != nil {
				proj = d.project()
			}
		}
	}
	switch sub {
	case "scope":
		if !need(2, "scope <skill> project|global") {
			return 2
		}
		if err := proj.setScope(args[0], args[1]); err != nil {
			return fail(err)
		}
		res, err := proj.sync()
		if err != nil {
			return fail(err)
		}
		if args[1] == skills.ScopeGlobal {
			fmt.Fprintf(stdout, "%s is now a central skill too. Run afk skills sync to copy it into every CLI.\n", args[0])
		} else {
			fmt.Fprintf(stdout, "%s is installed for this project.\n", args[0])
		}
		printSkillsResult(stdout, res, "")
		return 0
	case "help":
		fmt.Fprint(stdout, skillsHelp)
		return 0
	case "status", "list", "ls":
		if len(args) > 0 {
			fmt.Fprintf(stderr, "afk skills: unknown argument %q\n", args[0])
			return 2
		}
		s, err := d.env.Scan(d.targets)
		if err != nil {
			return fail(err)
		}
		if asJSON {
			return writeJSON(stdout, stderr, skillsJSON{Schema: "afk-skills/1", Status: s, Unsupported: nonNil(d.unsupported)})
		}
		fmt.Fprint(stdout, renderSkills(d, s))
		if proj != nil && !project {
			ps, err := proj.deps.env.Scan(proj.deps.targets)
			if err != nil {
				return fail(err)
			}
			fmt.Fprintf(stdout, "\nThis project (%s):\n", tildePath(ps.Central))
			fmt.Fprint(stdout, renderProjectSkills(proj, ps))
		}
		return 0
	case "sync":
		if len(args) > 0 {
			fmt.Fprintf(stderr, "afk skills: unknown argument %q\n", args[0])
			return 2
		}
		if dry {
			s, err := d.env.Scan(d.targets)
			if err != nil {
				return fail(err)
			}
			if asJSON {
				return writeJSON(stdout, stderr, map[string]any{"schema": "afk-skills-sync/1", "dry_run": true, "actions": nonNilA(s.Actions)})
			}
			if len(s.Actions) == 0 {
				fmt.Fprintln(stdout, "Nothing to sync.")
			}
			for _, a := range s.Actions {
				fmt.Fprintf(stdout, "would %-6s %s → %s\n", a.Kind, a.Skill, a.Path)
			}
			return 0
		}
		if project {
			if d.interactive && !asJSON {
				if err := proj.ask(d.stdin(), stdout); err != nil {
					return fail(err)
				}
			}
			res, err := proj.sync()
			if err != nil {
				return fail(err)
			}
			if asJSON {
				return writeJSON(stdout, stderr, map[string]any{"schema": "afk-skills-sync/1", "done": nonNilA(res.Done), "backup": res.Backup})
			}
			printSkillsResult(stdout, res, "Nothing to sync.")
			proj.noteUndecided(stdout)
			return 0
		}
		res, err := d.env.Sync(d.targets)
		if err != nil {
			return fail(err)
		}
		if asJSON {
			return writeJSON(stdout, stderr, map[string]any{"schema": "afk-skills-sync/1", "done": nonNilA(res.Done), "backup": res.Backup})
		}
		printSkillsResult(stdout, res, "Nothing to sync.")
		if proj != nil {
			if d.interactive {
				if err := proj.ask(d.stdin(), stdout); err != nil {
					return fail(err)
				}
			}
			pres, err := proj.sync()
			if err != nil {
				return fail(err)
			}
			if len(pres.Done) > 0 {
				fmt.Fprintln(stdout, "This project:")
				printSkillsResult(stdout, pres, "")
			}
			proj.noteUndecided(stdout)
		}
		return 0
	case "diff":
		if !need(2, "diff <skill> <cli>") {
			return 2
		}
		out, err := d.env.Diff(d.targets, args[0], args[1])
		if err != nil {
			return fail(err)
		}
		if out == "" {
			out = "No differences.\n"
		}
		fmt.Fprint(stdout, out)
		if wait {
			fmt.Fprint(stdout, "\nPress Enter to go back. ")
			_, _ = bufio.NewReader(d.stdin()).ReadString('\n')
		}
		return 0
	case "keep", "restore":
		if !need(2, sub+" <skill> <cli>") {
			return 2
		}
		var res *skills.Result
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
		printSkillsResult(stdout, res, "")
		if sub == "keep" {
			fmt.Fprintln(stdout, "Run afk skills sync to copy it into the other CLIs.")
		}
		return 0
	case "enable", "disable":
		if !need(2, sub+" <skill> <cli>") {
			return 2
		}
		known := false
		for _, t := range d.targets {
			known = known || t.Harness == args[1]
		}
		if !known {
			return fail(fmt.Errorf("%s is not an installed CLI with a skills folder", args[1]))
		}
		if err := d.env.SetEnabled(args[0], args[1], sub == "enable"); err != nil {
			return fail(err)
		}
		fmt.Fprintf(stdout, "%s %sd for %s. Run afk skills sync to apply it.\n", args[0], sub, args[1])
		return 0
	case "new":
		if len(args) < 1 && edit {
			// From the Skills tab: ask for the name here.
			fmt.Fprint(stdout, "New skill name (lowercase letters, digits, . _ -): ")
			name, _ := bufio.NewReader(d.stdin()).ReadString('\n')
			if name = strings.TrimSpace(name); name == "" {
				return 0
			}
			args = []string{name}
		}
		if len(args) < 1 {
			fmt.Fprintln(stderr, "afk skills: usage: afk skills new <name> [description] [--edit]")
			return 2
		}
		p, err := d.env.New(args[0], strings.Join(args[1:], " "))
		if err != nil {
			fail(err)
			if edit {
				fmt.Fprint(stdout, "Press Enter to go back. ")
				_, _ = bufio.NewReader(d.stdin()).ReadString('\n')
			}
			return 1
		}
		fmt.Fprintln(stdout, p)
		if edit {
			c := editorCmd(p)
			c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
			if err := c.Run(); err != nil {
				return fail(err)
			}
		}
		return 0
	}
	if sub == "edit" {
		// Open a central skill's text in the editor.
		if len(args) != 1 || !skills.ValidName(args[0]) {
			fmt.Fprintln(stderr, "afk skills: usage: afk skills edit <name>")
			return 2
		}
		p := filepath.Join(d.env.Central, args[0], "SKILL.md")
		if _, err := os.Stat(p); err != nil {
			return fail(fmt.Errorf("%s is not a central skill (a project skill is edited in its own folder)", args[0]))
		}
		c := editorCmd(p)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := c.Run(); err != nil {
			return fail(err)
		}
		return 0
	}
	fmt.Fprintf(stderr, "afk skills: unknown command %q\n\n%s", sub, skillsHelp)
	return 2
}

type skillsJSON struct {
	Schema string `json:"schema"`
	*skills.Status
	Unsupported []string `json:"unsupported"`
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func nonNilA(s []skills.Action) []skills.Action {
	if s == nil {
		return []skills.Action{}
	}
	return s
}

func writeJSON(stdout, stderr io.Writer, v any) int {
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		fmt.Fprintln(stderr, "afk:", err)
		return 1
	}
	return 0
}

func printSkillsResult(w io.Writer, res *skills.Result, none string) {
	if len(res.Done) == 0 && none != "" {
		fmt.Fprintln(w, none)
	}
	for _, a := range res.Done {
		fmt.Fprintf(w, "%-7s %s → %s\n", a.Kind, a.Skill, a.Path)
	}
	if res.Backup != "" {
		fmt.Fprintln(w, "Backup:", res.Backup)
	}
}

// cellMark is how a cell reads in the grid.
func cellMark(c skills.Cell) string {
	switch c {
	case skills.Synced:
		return "✓"
	case skills.Drifted:
		return "↻"
	case skills.Off, skills.Unmanaged:
		return "·"
	case skills.Pending:
		return "+"
	case skills.Removing, skills.Orphan:
		return "-"
	case skills.Conflict:
		return "!"
	}
	return "?"
}

const skillsLegend = "✓ in sync  ↻ changed in that CLI  · not enabled  – not supported\n+ next sync adds it  - next sync removes it  ! your own skill, left alone"

func renderSkills(d skillsDeps, s *skills.Status) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s · source %s\n", plural(len(s.Skills), "skill"), tildePath(s.Central))
	if len(s.Skills) == 0 {
		fmt.Fprintf(&b, "\nNo skills yet. Start one with: afk skills new <name>\n")
		return b.String()
	}
	cols := append([]string{}, harnessNames(s.Targets)...)
	unsup := append([]string{}, d.unsupported...)
	sort.Strings(unsup)
	w := 6
	for _, sk := range s.Skills {
		if len(sk.Name) > w {
			w = len(sk.Name)
		}
	}
	b.WriteString("\n" + pad("SKILL", w+2))
	for _, c := range append(cols, unsup...) {
		b.WriteString(pad(c, len(c)+2))
	}
	b.WriteString("\n")
	for _, sk := range s.Skills {
		b.WriteString(pad(sk.Name, w+2))
		for _, c := range cols {
			b.WriteString(pad(cellMark(sk.Cells[c]), len(c)+2))
		}
		for _, c := range unsup {
			b.WriteString(pad("–", len(c)+2))
		}
		b.WriteString("\n")
	}
	b.WriteString("\n" + skillsLegend + "\n")
	for _, dr := range s.Drift {
		fmt.Fprintf(&b, "\n%s changed in %s (%s differ). afk skills diff|keep|restore %s %s\n",
			dr.Skill, dr.Harness, plural(d.env.Changed(s.Targets, dr.Skill, dr.Harness), "line"), dr.Skill, dr.Harness)
	}
	for _, p := range s.Problems {
		fmt.Fprintln(&b, "problem:", p)
	}
	if n := len(s.Actions); n > 0 {
		fmt.Fprintf(&b, "\n%s waiting. Run afk skills sync.\n", plural(n, "change"))
	}
	return b.String()
}

func harnessNames(ts []skills.Target) []string {
	out := make([]string, len(ts))
	for i, t := range ts {
		out[i] = t.Harness
	}
	return out
}

func pad(s string, n int) string {
	if l := len([]rune(s)); l < n {
		return s + strings.Repeat(" ", n-l)
	}
	return s + " "
}

func tildePath(p string) string {
	if home, err := os.UserHomeDir(); err == nil && home != "" && strings.HasPrefix(p, home+string(os.PathSeparator)) {
		return "~" + strings.TrimPrefix(p, home)
	}
	return p
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return fmt.Sprintf("%d %ss", n, word)
}
