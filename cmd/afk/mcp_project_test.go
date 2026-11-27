package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/mcp"
)

const testProjectMCP = `{"mcpServers": {
  "db": {"command": "npx", "args": ["db-mcp"], "env": {"DB_URL": "${DB_URL}"}},
  "docs": {"type": "http", "url": "https://docs.example.com/mcp"},
  "leaky": {"command": "x", "env": {"API_KEY": "sk-123"}}
}}`

func projectMCPFixture(t *testing.T) (*projectMCP, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("needs git")
	}
	root := t.TempDir()
	if out, err := exec.Command("git", "init", "-q", root).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	if err := os.WriteFile(filepath.Join(root, ".mcp.json"), []byte(testProjectMCP), 0o644); err != nil {
		t.Fatal(err)
	}
	afk := t.TempDir()
	p := &projectMCP{root: root, native: []string{"claude"}, notes: map[string]string{}}
	p.user.env = mcp.Env{Config: filepath.Join(afk, "mcp.toml"), State: filepath.Join(afk, "state", "mcp.json")}
	p.deps.env = mcp.Env{Project: filepath.Join(root, ".mcp.json"), State: filepath.Join(afk, "state", "mcp-projects", "x.json"), Ask: true}
	p.deps.targets = []mcp.Target{{Harness: "gemini", File: filepath.Join(root, ".gemini", "settings.json"), Format: "gemini-json"}}
	return p, root
}

func TestProjectMCPAsk(t *testing.T) {
	p, root := projectMCPFixture(t)
	gem := filepath.Join(root, ".gemini", "settings.json")
	if res, err := p.sync(); err != nil || len(res.Done) != 0 {
		t.Fatalf("sync before choosing: %v %v", res, err)
	}
	var out bytes.Buffer
	p.noteUndecided(&out)
	if !strings.Contains(out.String(), "db, docs in .mcp.json wait") {
		t.Errorf("note: %q", out.String())
	}
	// db: this project. docs: every project. Enter would leave one.
	out.Reset()
	if err := p.ask(strings.NewReader("p\ng\n"), &out); err != nil {
		t.Fatal(err)
	}
	if _, err := p.sync(); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(gem)
	if err != nil || !strings.Contains(string(b), `"db"`) || strings.Contains(string(b), `"docs"`) {
		t.Fatalf("gemini's project file: %v\n%s", err, b)
	}
	ex, _ := os.ReadFile(filepath.Join(root, ".git", "info", "exclude"))
	if !strings.Contains(string(ex), "/.gemini/settings.json") {
		t.Errorf("exclude:\n%s", ex)
	}
	st, _ := exec.Command("git", "-C", root, "status", "--porcelain", "--untracked-files=all").Output()
	if strings.Contains(string(st), ".gemini") {
		t.Errorf("git sees AFK's file:\n%s", st)
	}
	got, err := mcp.Load(p.user.env.Config, nil)
	if err != nil || len(got) != 1 || got[0].Name != "docs" {
		t.Fatalf("mcp.toml: %+v %v", got, err)
	}
	// The skipped server says why, without its value.
	s, _ := p.deps.env.Scan(p.deps.targets)
	r := renderProjectMCP(p, s)
	for _, w := range []string{"db", "project", "docs", "global", "claude reads .mcp.json itself", "skipped: leaky"} {
		if !strings.Contains(r, w) {
			t.Errorf("missing %q in\n%s", w, r)
		}
	}
	if strings.Contains(r, "sk-123") {
		t.Error("the render shows a secret value")
	}
}

func TestProjectMCPTracked(t *testing.T) {
	_, root := projectMCPFixture(t)
	if err := os.MkdirAll(filepath.Join(root, ".gemini"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".gemini", "settings.json"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("git", "-C", root, "add", ".gemini/settings.json").CombinedOutput(); err != nil {
		t.Fatalf("git add: %v %s", err, out)
	}
	if !tracked(root, ".gemini/settings.json") || tracked(root, "opencode.json") {
		t.Error("tracked() is wrong")
	}
}
