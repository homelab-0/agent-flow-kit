package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/skills"
)

func projectFixture(t *testing.T) (*projectSkills, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("needs git")
	}
	root := t.TempDir()
	if out, err := exec.Command("git", "init", "-q", root).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	src := filepath.Join(root, ".agents", "skills")
	if err := os.MkdirAll(filepath.Join(src, "deploy"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "deploy", "SKILL.md"), []byte("---\nname: deploy\n---\nship\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	afk := t.TempDir()
	p := &projectSkills{root: root, user: skills.Env{Central: filepath.Join(afk, "skills"), State: filepath.Join(afk, "state", "skills.json")},
		native: []string{"codex"}}
	p.deps.env = skills.Env{Central: src, State: filepath.Join(afk, "state", "skills-projects", "x.json"), Ask: true}
	p.deps.targets = []skills.Target{{Harness: "claude", Dir: filepath.Join(root, ".claude", "skills")}}
	return p, root
}

func TestProjectSkillsAsk(t *testing.T) {
	p, root := projectFixture(t)
	copyDir := filepath.Join(root, ".claude", "skills", "deploy")
	// Nothing is copied until a scope is chosen.
	if res, err := p.sync(); err != nil || len(res.Done) != 0 {
		t.Fatalf("sync before choosing: %v %v", res, err)
	}
	var out bytes.Buffer
	p.noteUndecided(&out)
	if !strings.Contains(out.String(), "deploy in .agents/skills waits") {
		t.Errorf("note: %q", out.String())
	}
	// "p" installs it for this project: claude gets a copy, git ignores it.
	out.Reset()
	if err := p.ask(strings.NewReader("p\n"), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "p) this project only, g) every project") {
		t.Errorf("prompt: %q", out.String())
	}
	if _, err := p.sync(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(copyDir, "SKILL.md")); err != nil {
		t.Fatalf("claude's project copy: %v", err)
	}
	ex, _ := os.ReadFile(filepath.Join(root, ".git", "info", "exclude"))
	if !strings.Contains(string(ex), "/.claude/skills/deploy/") || !strings.Contains(string(ex), excludeMark) {
		t.Errorf("exclude:\n%s", ex)
	}
	st, _ := exec.Command("git", "-C", root, "status", "--porcelain", "--untracked-files=all").Output()
	if strings.Contains(string(st), ".claude") {
		t.Errorf("git sees AFK's copy:\n%s", st)
	}
	// Global copies it into central and removes the project copy and
	// its exclude line.
	if err := p.setScope("deploy", skills.ScopeGlobal); err != nil {
		t.Fatal(err)
	}
	if _, err := p.sync(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(p.user.Central, "deploy", "SKILL.md")); err != nil {
		t.Errorf("central copy: %v", err)
	}
	if _, err := os.Stat(copyDir); !os.IsNotExist(err) {
		t.Errorf("the project copy should be gone: %v", err)
	}
	ex, _ = os.ReadFile(filepath.Join(root, ".git", "info", "exclude"))
	if strings.Contains(string(ex), "/.claude/skills/deploy/") {
		t.Errorf("exclude line left behind:\n%s", ex)
	}
	// The grid shows the scope and the CLI that reads .agents/skills.
	s, err := p.deps.env.Scan(p.deps.targets)
	if err != nil {
		t.Fatal(err)
	}
	g := renderProjectSkills(p, s)
	if !strings.Contains(g, "global") || !strings.Contains(g, "codex reads .agents/skills itself") {
		t.Errorf("grid:\n%s", g)
	}
}

func TestProjectSkillsAskLater(t *testing.T) {
	p, _ := projectFixture(t)
	var out bytes.Buffer
	if err := p.ask(strings.NewReader("\n"), &out); err != nil {
		t.Fatal(err)
	}
	if n, _ := p.undecided(); len(n) != 1 {
		t.Errorf("Enter should leave it undecided: %v", n)
	}
	if err := p.ask(strings.NewReader(""), &out); err != nil { // end of input
		t.Fatal(err)
	}
}
