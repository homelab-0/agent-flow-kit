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
