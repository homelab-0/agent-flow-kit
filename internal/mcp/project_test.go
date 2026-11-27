package mcp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const projectJSON = `{
  "mcpServers": {
    "docs": {"type": "http", "url": "https://docs.example.com/mcp", "headers": {"Authorization": "Bearer ${DOCS_TOKEN}"}},
    "db": {"command": "npx", "args": ["db-mcp"], "env": {"DB_URL": "${DB_URL}"}},
    "leaky": {"command": "x", "env": {"API_KEY": "sk-123"}},
    "stream": {"type": "sse", "url": "https://s.example.com/sse"},
    "creds": {"type": "http", "url": "https://bob:hunter2@c.example.com/mcp"},
    "odd": {"type": "http", "url": "ftp://o.example.com/?token=abc123"}
  }
}`

func TestLoadProject(t *testing.T) {
	p := filepath.Join(t.TempDir(), ".mcp.json")
	if err := os.WriteFile(p, []byte(projectJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	servers, skipped, err := LoadProject(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(servers) != 2 || servers[0].Name != "db" || servers[1].Name != "docs" {
		t.Fatalf("servers %+v", servers)
	}
	if servers[0].Command != "npx" || strings.Join(servers[0].Env, ",") != "DB_URL" {
		t.Errorf("db %+v", servers[0])
	}
	if servers[1].BearerEnv != "DOCS_TOKEN" || servers[1].Kind != "http" {
		t.Errorf("docs %+v", servers[1])
	}
	if !strings.Contains(skipped["leaky"], "API_KEY is set to a value") || !strings.Contains(skipped["stream"], "sse") {
		t.Errorf("skipped %v", skipped)
	}
	if strings.Contains(skipped["leaky"], "sk-123") {
		t.Error("a skipped reason repeats the value")
	}
	for n, secret := range map[string]string{"creds": "hunter2", "odd": "abc123"} {
		if skipped[n] == "" || strings.Contains(skipped[n], secret) {
			t.Errorf("skipped[%s] = %q", n, skipped[n])
		}
	}
	if s, sk, err := LoadProject(filepath.Join(t.TempDir(), "none.json")); err != nil || s != nil || len(sk) != 0 {
		t.Errorf("missing file: %v %v %v", s, sk, err)
	}
}

func TestProjectScopes(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".mcp.json"), []byte(projectJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	env := Env{Project: filepath.Join(root, ".mcp.json"), State: filepath.Join(t.TempDir(), "p.json"), Ask: true}
	targets := []Target{{Harness: "gemini", File: filepath.Join(root, ".gemini", "settings.json"), Format: "gemini-json"}}
	s, err := env.Scan(targets)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Actions) != 0 || s.Rows[0].Cells["gemini"] != Ask {
		t.Fatalf("undecided servers must wait: %+v %+v", s.Actions, s.Rows)
	}
	if len(s.Problems) != 4 {
		t.Errorf("problems %v", s.Problems)
	}
	if err := env.SetScope("db", ScopeProject); err != nil {
		t.Fatal(err)
	}
	if err := env.SetScope("docs", ScopeGlobal); err != nil {
		t.Fatal(err)
	}
	res, err := env.Sync(targets)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Done) != 1 || res.Done[0].Server != "db" {
		t.Fatalf("done %+v", res.Done)
	}
	b, _ := os.ReadFile(targets[0].File)
	if !strings.Contains(string(b), `"DB_URL": "$DB_URL"`) {
		t.Errorf("gemini file:\n%s", b)
	}
	s, _ = env.Scan(targets)
	cells := map[string]Cell{}
	for _, r := range s.Rows {
		cells[r.Name] = r.Cells["gemini"]
	}
	if cells["db"] != Synced || cells["docs"] != Global {
		t.Errorf("cells %v", cells)
	}
	// Changing db to global takes the project copy out again.
	if err := env.SetScope("db", ScopeGlobal); err != nil {
		t.Fatal(err)
	}
	if res, err := env.Sync(targets); err != nil || len(res.Done) != 1 || res.Done[0].Kind != "remove" {
		t.Fatalf("remove: %+v %v", res, err)
	}
}

func TestAddToConfig(t *testing.T) {
	cfg := filepath.Join(t.TempDir(), "mcp.toml")
	if err := os.WriteFile(cfg, []byte("# mine\n[[server]]\nname = \"a\"\nurl = \"https://a.example.com/mcp\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	db := Server{Name: "db", Kind: "stdio", Via: "stdio", Command: "npx", Args: []string{"db-mcp"}, Env: []string{"DB_URL"}, All: true}
	docs := Server{Name: "docs", Kind: "http", Via: "http", URL: "https://docs.example.com/mcp", BearerEnv: "DOCS_TOKEN", All: true}
	for _, s := range []Server{db, docs, db} {
		if err := AddToConfig(cfg, nil, s); err != nil {
			t.Fatal(err)
		}
	}
	got, err := Load(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[1].Name != "db" || got[1].Env[0] != "DB_URL" || got[2].BearerEnv != "DOCS_TOKEN" {
		t.Fatalf("mcp.toml now %+v", got)
	}
	b, _ := os.ReadFile(cfg)
	if !strings.HasPrefix(string(b), "# mine\n") {
		t.Errorf("the file's own text was lost:\n%s", b)
	}
	if err := AddToConfig(cfg, nil, Server{Name: "a", Kind: "http", URL: "https://other.example.com/mcp"}); err == nil {
		t.Error("a different server of the same name should be refused")
	}
}
