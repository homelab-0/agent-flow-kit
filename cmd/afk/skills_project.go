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
	"strings"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/skills"
	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

// A repository's own skills live in <repo>/.agents/skills. Most CLIs read
// that folder themselves; for the rest AFK copies a skill into the CLI's
// project folder (claude: .claude/skills), and lists the copy in the
// repository's .git/info/exclude so it is never committed. Before it
// copies a skill anywhere AFK asks: this project only, or every project
// (copied into the central skills folder and synced like any other).

// projectSkillsDir is where a repository keeps its skills.
const projectSkillsDir = ".agents/skills"

type projectSkills struct {
	root   string     // the repository
	user   skills.Env // the central (global) skills
	deps   skillsDeps // Central is <root>/.agents/skills, Ask is set
	native []string   // CLIs that read .agents/skills themselves
}

// repoRoot is the git repository dir is in, else dir itself.
func repoRoot(dir string) string {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return dir
	}
	if r := strings.TrimSpace(string(out)); r != "" {
		return r
	}
	return dir
}

// projectSkillsFor is the repository at root's skills, or nil when it
// has no .agents/skills folder.
func projectSkillsFor(root string, he harness.Env, getenv func(string) string) *projectSkills {
	src := filepath.Join(root, filepath.FromSlash(projectSkillsDir))
	if fi, err := os.Stat(src); err != nil || !fi.IsDir() {
		return nil
	}
	sum := sha256.Sum256([]byte(root))
	dir := config.PathsFor(he.Home, getenv).Dir
	p := &projectSkills{root: root, user: skillsEnvFor(he.Home, getenv)}
	p.deps.env = skills.Env{
		Central: src,
		State:   filepath.Join(dir, "state", "skills-projects", hex.EncodeToString(sum[:6])+".json"),
		Ask:     true,
	}
	r := harness.Discover(context.Background(), he, harness.Options{SkipVersion: true})
	for _, h := range r.Installed() {
		m, ok := harness.ManifestFor(h.Name)
		pd := ""
		if ok {
			pd = m.Skills.ProjectDir
		}
		switch filepath.ToSlash(filepath.Clean(pd)) {
		case ".":
			p.deps.unsupported = append(p.deps.unsupported, h.Name)
		case projectSkillsDir:
			p.native = append(p.native, h.Name)
		default:
			p.deps.targets = append(p.deps.targets, skills.Target{Harness: h.Name, Dir: filepath.Join(root, filepath.FromSlash(pd))})
		}
	}
	return p
}

// sync copies project-scoped skills into the CLIs' project folders and
// keeps .git/info/exclude in step with AFK's copies.
func (p *projectSkills) sync() (*skills.Result, error) {
	res, err := p.deps.env.Sync(p.deps.targets)
	if err != nil {
		return nil, err
	}
	if err := p.exclude(res.Done); err != nil {
		return res, fmt.Errorf("synced, but couldn't update .git/info/exclude: %w", err)
	}
	return res, nil
}

// setScope records a skill's scope. Global first copies it into the
// central skills folder.
func (p *projectSkills) setScope(skill, scope string) error {
	if scope == skills.ScopeGlobal {
		if err := p.deps.env.CopyInto(skill, p.user.Central); err != nil {
			return err
		}
	}
	return p.deps.env.SetScope(skill, scope)
}

// undecided are the project skills still waiting for a scope.
func (p *projectSkills) undecided() ([]string, error) {
	st, err := p.deps.env.Scan(p.deps.targets)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, sk := range st.Skills {
		if sk.Central && sk.Scope == "" {
			out = append(out, sk.Name)
		}
	}
	return out, nil
}

// ask puts each undecided skill to the user: p this project, g every
// project, Enter to decide later.
func (p *projectSkills) ask(in io.Reader, out io.Writer) error {
	names, err := p.undecided()
	if err != nil || len(names) == 0 {
		return err
	}
	r := bufio.NewReader(in)
	for _, n := range names {
		fmt.Fprintf(out, "Project skill %s: install it for p) this project only, g) every project, or Enter to decide later? ", n)
		line, err := r.ReadString('\n')
		var scope string
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "p", "project":
			scope = skills.ScopeProject
		case "g", "global":
			scope = skills.ScopeGlobal
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

// excludeMark heads AFK's lines in .git/info/exclude.
const excludeMark = "# afk: copies AFK made of this repository's skills and MCP servers"

// exclude adds AFK's new copies to .git/info/exclude and drops the ones
// it removed. Nothing happens outside a git repository.
func (p *projectSkills) exclude(done []skills.Action) error {
	var add, drop []string
	for _, a := range done {
		rel, err := filepath.Rel(p.root, a.Path)
		if err != nil || strings.HasPrefix(rel, "..") {
			continue
		}
		pat := "/" + filepath.ToSlash(rel) + "/"
		if a.Kind == "remove" {
			drop = append(drop, pat)
		} else {
			add = append(add, pat)
		}
	}
	return gitExclude(p.root, add, drop)
}

// gitExclude adds patterns to the repository's .git/info/exclude, under
// AFK's mark, and takes others out. Nothing happens outside a git
// repository.
func gitExclude(root string, add, drop []string) error {
	if len(add) == 0 && len(drop) == 0 {
		return nil
	}
	out, err := exec.Command("git", "-C", root, "rev-parse", "--git-path", "info/exclude").Output()
	if err != nil {
		return nil // not a git repository
	}
	file := strings.TrimSpace(string(out))
	if !filepath.IsAbs(file) {
		file = filepath.Join(root, file)
	}
	b, err := os.ReadFile(file)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(b) == 0 {
		lines = nil
	}
	has := map[string]bool{}
	for _, l := range lines {
		has[l] = true
	}
	gone := map[string]bool{}
	for _, d := range drop {
		gone[d] = true
	}
	var keep, fresh []string
	for _, l := range lines {
		if !gone[l] {
			keep = append(keep, l)
		}
	}
	for _, a := range add {
		if !has[a] {
			fresh = append(fresh, a)
			has[a] = true
		}
	}
	if len(fresh) == 0 && len(keep) == len(lines) {
		return nil
	}
	if len(fresh) > 0 {
		if !has[excludeMark] {
			keep = append(keep, excludeMark)
		}
		keep = append(keep, fresh...)
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	return statefile.WriteFile(file, []byte(strings.Join(keep, "\n")+"\n"))
}

// noteUndecided says which project skills still wait for a scope.
func (p *projectSkills) noteUndecided(w io.Writer) {
	names, err := p.undecided()
	if err != nil || len(names) == 0 {
		return
	}
	fmt.Fprintf(w, "%s in %s %s for you to choose: afk skills scope <skill> project|global\n",
		strings.Join(names, ", "), projectSkillsDir, map[bool]string{true: "waits", false: "wait"}[len(names) == 1])
}

// renderProjectSkills is the project's skills as a grid: the CLIs AFK
// copies into, then the ones that read .agents/skills themselves.
func renderProjectSkills(p *projectSkills, s *skills.Status) string {
	if len(s.Skills) == 0 {
		return "No skills in " + projectSkillsDir + ".\n"
	}
	var b strings.Builder
	w := 6
	for _, sk := range s.Skills {
		w = max(w, len(sk.Name))
	}
	cols := harnessNames(s.Targets)
	b.WriteString(pad("SKILL", w+2) + pad("SCOPE", 10))
	for _, c := range append(append(append([]string{}, cols...), p.native...), p.deps.unsupported...) {
		b.WriteString(pad(c, len(c)+2))
	}
	b.WriteString("\n")
	for _, sk := range s.Skills {
		scope := sk.Scope
		if scope == "" {
			scope = "?"
		}
		if !sk.Central {
			scope = "gone"
		}
		b.WriteString(pad(sk.Name, w+2) + pad(scope, 10))
		for _, c := range cols {
			b.WriteString(pad(projectMark(sk.Cells[c]), len(c)+2))
		}
		for _, c := range p.native {
			m := "✓"
			if !sk.Central {
				m = "·"
			}
			b.WriteString(pad(m, len(c)+2))
		}
		for _, c := range p.deps.unsupported {
			b.WriteString(pad("–", len(c)+2))
		}
		b.WriteString("\n")
	}
	if len(p.native) > 0 {
		fmt.Fprintf(&b, "%s %s %s %s.\n", strings.Join(p.native, ", "), map[bool]string{true: "reads", false: "read"}[len(p.native) == 1], projectSkillsDir, map[bool]string{true: "itself", false: "themselves"}[len(p.native) == 1])
	}
	return b.String()
}

func projectMark(c skills.Cell) string {
	switch c {
	case skills.Ask:
		return "?"
	case skills.Global:
		return "g"
	}
	return cellMark(c)
}

// projectSkillsDo runs a Skills tab action on the project's skills.
func projectSkillsDo(p *projectSkills, op string, args ...string) (string, error) {
	two := func() (string, string, error) {
		if len(args) != 2 {
			return "", "", fmt.Errorf("skills %s needs a skill and a second argument", op)
		}
		return args[0], args[1], nil
	}
	d := p.deps
	switch op {
	case "scope":
		sk, scope, err := two()
		if err != nil {
			return "", err
		}
		if err := p.setScope(sk, scope); err != nil {
			return "", err
		}
		if _, err := p.sync(); err != nil {
			return "", err
		}
		if scope == skills.ScopeGlobal {
			return sk + " is now a central skill too. Press s to copy it into every CLI.", nil
		}
		return sk + " is installed for this project.", nil
	case "keep", "restore":
		sk, h, err := two()
		if err != nil {
			return "", err
		}
		if op == "keep" {
			if _, err := d.env.Keep(d.targets, sk, h); err != nil {
				return "", err
			}
			return fmt.Sprintf("%s's %s is now the project's copy. Press s to copy it into the other CLIs.", h, sk), nil
		}
		res, err := d.env.Restore(d.targets, sk, h)
		if err != nil {
			return "", err
		}
		_ = p.exclude(res.Done)
		return fmt.Sprintf("Put the project's %s back in %s (its copy is backed up).", sk, h), nil
	case "enable", "disable":
		sk, h, err := two()
		if err != nil {
			return "", err
		}
		if err := d.env.SetEnabled(sk, h, op == "enable"); err != nil {
			return "", err
		}
		return fmt.Sprintf("%s %sd for %s in this project. Press s to apply it.", sk, op, h), nil
	}
	return "", fmt.Errorf("unknown project skills action %q", op)
}
