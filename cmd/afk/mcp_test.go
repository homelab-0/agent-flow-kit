package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/mcp"
)

func testMCP(t *testing.T, toml string) (mcpDeps, string) {
	t.Helper()
	home := t.TempDir()
	s := config.Settings{Gateways: map[string]config.Gateway{
		"homelab": {URL: "https://gw.lan/v1"},
		"work":    {URL: "https://w.example/v1", MCP: "https://w.example/tools/mcp"},
	}}
	env := mcpEnvFor(home, func(string) string { return "" }, s)
	if err := os.MkdirAll(filepath.Dir(env.Config), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(env.Config, []byte(toml), 0o644); err != nil {
		t.Fatal(err)
	}
	return mcpDeps{env: env, unsupported: []string{"pi"}, getenv: func(string) string { return "" },
		targets: []mcp.Target{{Harness: "claude", File: filepath.Join(home, ".claude.json"), Format: "claude-json"}}}, home
}

func mcpRun(d mcpDeps, args ...string) (string, int) {
	var out, errb bytes.Buffer
	code := runMCP(d, args, &out, &errb)
	return out.String() + errb.String(), code
}

func TestMCPGatewayEndpoints(t *testing.T) {
	d, _ := testMCP(t, "")
	if g := d.env.Gateways; g["homelab"] != "https://gw.lan/mcp" || g["work"] != "https://w.example/tools/mcp" {
		t.Errorf("endpoints %v", g)
	}
}

func TestMCPCommandFlow(t *testing.T) {
	d, home := testMCP(t, `
[[server]]
name = "github"
via = "homelab"
bearer = "env:GH"
`)
	out, code := mcpRun(d)
	if code != 0 || !strings.Contains(out, "github") || !strings.Contains(out, "untested") || !strings.Contains(out, "1 change waiting") {
		t.Fatalf("status %d:\n%s", code, out)
	}
	if out, code = mcpRun(d, "sync"); code != 0 || !strings.Contains(out, "add     github in claude") {
		t.Fatalf("sync %d: %s", code, out)
	}
	b, _ := os.ReadFile(filepath.Join(home, ".claude.json"))
	if !strings.Contains(string(b), "https://gw.lan/mcp") || !strings.Contains(string(b), "${GH}") {
		t.Errorf("claude.json: %s", b)
	}
	if out, code = mcpRun(d, "test", "github"); code != 1 || !strings.Contains(out, "GH is not set") {
		t.Errorf("test without the token: %d %s", code, out)
	}
	out, _ = mcpRun(d, "--json")
	var js struct {
		Schema string
		Rows   []mcp.Row
		Tested map[string]mcp.Tested
	}
	if err := json.Unmarshal([]byte(out), &js); err != nil || js.Schema != "afk-mcp/1" || js.Rows[0].Cells["claude"] != mcp.Synced || js.Tested["github"].OK {
		t.Fatalf("json %v: %s", err, out)
	}
	if _, code := mcpRun(d, "disable", "github", "nope"); code != 1 {
		t.Error("an unknown CLI should fail")
	}
	if _, code := mcpRun(d, "keep", "x"); code != 2 {
		t.Error("usage")
	}
}

// A server typed into the MCP tab lands in mcp.toml as a [[server]]; a
// line that doesn't make a valid one changes nothing.
func TestAddMCPServerFromALine(t *testing.T) {
	dir := t.TempDir()
	d := mcpDeps{env: mcp.Env{Config: filepath.Join(dir, "afk", "mcp.toml"), Gateways: map[string]string{"work": "https://gw.example/mcp"}}}
	for _, bad := range []string{
		"github",                                   // nothing after the name
		"GitHub https://api.example/mcp",           // not a server name
		"gh https://user:pw@api.example/mcp",       // a password in the address
		"gh https://api.example/mcp ghp_secret123", // a token, not a reference
		"gh https://api.example/mcp env:",          // no variable name
		"tools via:nowhere",                        // not a gateway in config.toml
		"tools via:work extra",
	} {
		if _, err := addMCPServer(d, bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
	if _, err := os.Stat(d.env.Config); err == nil {
		t.Fatal("a refused line created mcp.toml")
	}
	for _, good := range []string{
		"github https://api.example/mcp env:GITHUB_MCP_TOKEN",
		"docs https://docs.example/mcp",
		"playwright npx @playwright/mcp@latest --headless",
		"tools via:work",
	} {
		if _, err := addMCPServer(d, good); err != nil {
			t.Fatalf("%q: %v", good, err)
		}
	}
	if _, err := addMCPServer(d, "github https://other.example/mcp"); err == nil {
		t.Error("a second server with the same name was accepted")
	}
	got, err := mcp.Load(d.env.Config, d.env.Gateways)
	if err != nil || len(got) != 4 {
		t.Fatalf("%d servers, %v", len(got), err)
	}
	by := map[string]mcp.Server{}
	for _, s := range got {
		by[s.Name] = s
	}
	if s := by["github"]; s.Kind != "http" || s.URL != "https://api.example/mcp" || s.BearerEnv != "GITHUB_MCP_TOKEN" {
		t.Errorf("github: %+v", s)
	}
	if s := by["playwright"]; s.Kind != "stdio" || s.Command != "npx" || len(s.Args) != 2 || s.Args[1] != "--headless" {
		t.Errorf("playwright: %+v", s)
	}
	if s := by["tools"]; s.Via != "work" || s.URL != "https://gw.example/mcp" {
		t.Errorf("tools: %+v", s)
	}
	raw, _ := os.ReadFile(d.env.Config)
	if strings.Contains(string(raw), "ghp_secret123") || !strings.Contains(string(raw), "# MCP servers AFK writes") {
		t.Errorf("mcp.toml:\n%s", raw)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "afk", ".mcp-*")); len(left) != 0 {
		t.Errorf("scratch files left behind: %v", left)
	}
}

func TestMCPImportCommand(t *testing.T) {
	d, home := testMCP(t, "")
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(`{"mcpServers": {"linear": {"type": "http", "url": "https://mcp.linear.app/mcp"}, "old": {"type": "sse", "url": "https://o.example/sse"}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	out, code := mcpRun(d, "import")
	if code != 0 || !strings.Contains(out, "linear") || !strings.Contains(out, "can't import: an sse server") || !strings.Contains(out, "afk mcp import --all") {
		t.Fatalf("list %d:\n%s", code, out)
	}
	if out, code = mcpRun(d, "import", "--all"); code != 0 || !strings.Contains(out, "Added linear to") {
		t.Fatalf("import %d:\n%s", code, out)
	}
	b, _ := os.ReadFile(d.env.Config)
	if !strings.Contains(string(b), `name = "linear"`) {
		t.Errorf("mcp.toml:\n%s", b)
	}
	if out, code = mcpRun(d, "import", "old"); code == 0 {
		t.Errorf("importing an sse server by name should fail:\n%s", out)
	}
}
