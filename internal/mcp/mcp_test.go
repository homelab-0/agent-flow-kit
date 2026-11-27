package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The test binary doubles as a stdio MCP server.
func TestMain(m *testing.M) {
	if os.Getenv("AFK_FAKE_MCP") == "1" {
		fakeStdio()
		return
	}
	os.Exit(m.Run())
}

func fakeStdio() {
	sc := bufio.NewScanner(os.Stdin)
	fmt.Println("not json: a log line")
	for sc.Scan() {
		var req struct {
			ID     *int   `json:"id"`
			Method string `json:"method"`
		}
		if json.Unmarshal(sc.Bytes(), &req) != nil || req.ID == nil {
			continue
		}
		var res any = map[string]any{"protocolVersion": ProtocolVersion, "capabilities": map[string]any{}, "serverInfo": map[string]any{"name": "fake"}}
		if req.Method == "tools/list" {
			res = map[string]any{"tools": []any{map[string]any{"name": "a"}, map[string]any{"name": "b"}}}
		}
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": *req.ID, "result": res})
		fmt.Println(string(b))
	}
}

type fixture struct {
	env     Env
	home    string
	targets []Target
}

func newFixture(t *testing.T, toml string) *fixture {
	t.Helper()
	home := t.TempDir()
	cfg := filepath.Join(home, ".config", "afk")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg, "mcp.toml"), []byte(toml), 0o644); err != nil {
		t.Fatal(err)
	}
	n := 0
	return &fixture{
		home: home,
		env: Env{Config: filepath.Join(cfg, "mcp.toml"), State: filepath.Join(cfg, "state", "mcp.json"),
			Gateways: map[string]string{"homelab": "https://gw.lan/mcp"},
			Now:      func() time.Time { n++; return time.Date(2026, 11, 27, 3, 0, n, 0, time.UTC) }},
		targets: []Target{
			{Harness: "claude", File: filepath.Join(home, ".claude.json"), Format: "claude-json"},
			{Harness: "codex", File: filepath.Join(home, ".codex", "config.toml"), Format: "codex-toml"},
			{Harness: "copilot", File: filepath.Join(home, ".copilot", "mcp-config.json"), Format: "copilot-json"},
		},
	}
}

func (f *fixture) write(t *testing.T, rel, s string) {
	t.Helper()
	p := filepath.Join(f.home, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) read(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(f.home, rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

const servers = `
[[server]]
name = "github"
via = "homelab"
path = "/mcp/github"
bearer = "env:GH_MCP_TOKEN"

[[server]]
name = "playwright"
command = ["npx", "@playwright/mcp@latest"]
harnesses = ["claude", "codex"]
`

func TestLoadRejectsSecretsAndBadServers(t *testing.T) {
	for _, bad := range []string{
		`[[server]]
name = "x"
url = "https://u:p@h/mcp"`,
		`[[server]]
name = "x"
url = "https://h/mcp"
bearer = "sk-123"`,
		`[[server]]
name = "x"
command = ["a"]
env = ["TOKEN=abc"]`,
		`[[server]]
name = "x"
via = "nowhere"`,
		`[[server]]
name = "Bad Name"
command = ["a"]`,
	} {
		f := newFixture(t, bad)
		if _, err := Load(f.env.Config, f.env.Gateways); err == nil {
			t.Errorf("accepted:\n%s", bad)
		}
	}
	f := newFixture(t, servers)
	s, err := Load(f.env.Config, f.env.Gateways)
	if err != nil || len(s) != 2 || s[0].URL != "https://gw.lan/mcp/github" || s[0].BearerEnv != "GH_MCP_TOKEN" || !s[0].All || s[1].Command != "npx" {
		t.Fatalf("%v %+v", err, s)
	}
}

func TestSyncWritesEachFormatAndKeepsTheRest(t *testing.T) {
	f := newFixture(t, servers)
	f.write(t, ".claude.json", `{"oauthAccount":{"x":1},"projects":{},"mcpServers":{"mine":{"type":"stdio","command":"me"}}}`)
	f.write(t, ".codex/config.toml", "# my settings\nmodel = \"gpt-6\"\n\n[mcp_servers.mine]\ncommand = \"me\"\n")
	st, err := f.env.Scan(f.targets)
	if err != nil {
		t.Fatal(err)
	}
	// copilot can't take a bearer by variable name; playwright isn't for it.
	if c := st.Rows[0].Cells["copilot"]; c != Unsupported {
		t.Errorf("github in copilot: %s", c)
	}
	if c := st.Rows[1].Cells["copilot"]; c != Off {
		t.Errorf("playwright in copilot: %s", c)
	}
	res, err := f.env.Sync(f.targets)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Done) != 4 || res.Backup == "" {
		t.Fatalf("done %+v", res)
	}
	claude := f.read(t, ".claude.json")
	if !strings.HasPrefix(claude, "{\n  \"oauthAccount\"") || !strings.Contains(claude, `"mine"`) ||
		!strings.Contains(claude, `"Authorization": "Bearer ${GH_MCP_TOKEN}"`) || !strings.Contains(claude, `"url": "https://gw.lan/mcp/github"`) {
		t.Errorf("claude.json:\n%s", claude)
	}
	if fi, _ := os.Stat(filepath.Join(f.home, ".claude.json")); fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", fi.Mode())
	}
	codex := f.read(t, ".codex/config.toml")
	if !strings.HasPrefix(codex, "# my settings\nmodel = \"gpt-6\"\n\n[mcp_servers.mine]\ncommand = \"me\"\n\n"+codexBegin) ||
		!strings.Contains(codex, "[mcp_servers.github]\nurl = \"https://gw.lan/mcp/github\"\nbearer_token_env_var = \"GH_MCP_TOKEN\"\n") ||
		!strings.Contains(codex, "[mcp_servers.playwright]\ncommand = \"npx\"\nargs = [\"@playwright/mcp@latest\"]\n") {
		t.Errorf("config.toml:\n%s", codex)
	}
	st, _ = f.env.Scan(f.targets)
	if len(st.Actions) != 0 || st.Rows[0].Cells["claude"] != Synced || st.Rows[1].Cells["codex"] != Synced {
		t.Errorf("after sync: %+v %+v", st.Actions, st.Rows)
	}
	// A secret never lands in a file.
	t.Setenv("GH_MCP_TOKEN", "sekrit")
	if _, err := f.env.Sync(f.targets); err != nil || strings.Contains(f.read(t, ".claude.json"), "sekrit") {
		t.Error("a token value was written")
	}
}

func TestDriftConflictAndRemove(t *testing.T) {
	f := newFixture(t, servers)
	f.targets = f.targets[:2]
	f.write(t, ".codex/config.toml", "[mcp_servers.playwright]\ncommand = \"mine\"\n")
	if _, err := f.env.Sync(f.targets); err != nil {
		t.Fatal(err)
	}
	st, _ := f.env.Scan(f.targets)
	if c := st.Rows[1].Cells["codex"]; c != Conflict {
		t.Fatalf("your own codex entry: %s", c)
	}
	if !strings.Contains(f.read(t, ".codex/config.toml"), "command = \"mine\"") {
		t.Error("your own entry was changed")
	}
	// Edit AFK's claude entry: drift, never overwritten by a sync.
	b := strings.Replace(f.read(t, ".claude.json"), "@playwright/mcp@latest", "@playwright/mcp@1.0", 1)
	f.write(t, ".claude.json", b)
	st, _ = f.env.Scan(f.targets)
	if st.Rows[1].Cells["claude"] != Drifted || len(st.Drift) != 1 {
		t.Fatalf("drift: %+v", st.Rows[1])
	}
	f.env.Sync(f.targets)
	if !strings.Contains(f.read(t, ".claude.json"), "@1.0") {
		t.Fatal("sync overwrote an edit")
	}
	if _, err := f.env.Restore(f.targets, "playwright", "claude"); err != nil || strings.Contains(f.read(t, ".claude.json"), "@1.0") {
		t.Fatalf("restore: %v", err)
	}
	// Off for claude here: the next sync takes AFK's entry out.
	if err := f.env.SetEnabled("playwright", "claude", false); err != nil {
		t.Fatal(err)
	}
	res, _ := f.env.Sync(f.targets)
	if len(res.Done) != 1 || res.Done[0].Kind != "remove" || strings.Contains(f.read(t, ".claude.json"), "playwright") {
		t.Errorf("remove: %+v", res)
	}
	// Dropped from mcp.toml: AFK's codex entry for github goes; the
	// section disappears when it's empty.
	f.write(t, ".config/afk/mcp.toml", "")
	f.env.Sync(f.targets)
	if c := f.read(t, ".codex/config.toml"); strings.Contains(c, codexBegin) || !strings.Contains(c, "command = \"mine\"") {
		t.Errorf("codex after removing everything:\n%s", c)
	}
}

func TestFailedSyncPutsFilesBack(t *testing.T) {
	f := newFixture(t, servers)
	f.targets = f.targets[:2]
	orig := `{"keep":true}`
	f.write(t, ".claude.json", orig)
	// codex's file can't be written: its directory is read-only.
	f.write(t, ".codex/config.toml", "model = \"x\"\n")
	dir := filepath.Join(f.home, ".codex")
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	if os.Geteuid() == 0 {
		t.Skip("root writes into read-only directories")
	}
	if _, err := f.env.Sync(f.targets); err == nil {
		t.Fatal("sync should fail")
	}
	if got := f.read(t, ".claude.json"); got != orig {
		t.Errorf("claude.json wasn't put back: %s", got)
	}
	if st, _ := f.env.Scan(f.targets); st.Rows[0].Cells["claude"] != Pending {
		t.Error("a failed sync was recorded")
	}
}

func TestBrokenFileIsLeftAlone(t *testing.T) {
	f := newFixture(t, servers)
	f.targets = f.targets[:1]
	f.write(t, ".claude.json", `{"oops":`)
	st, err := f.env.Scan(f.targets)
	if err != nil || st.Rows[0].Cells["claude"] != Broken || len(st.Actions) != 0 || len(st.Problems) != 1 {
		t.Fatalf("%v %+v", err, st)
	}
}

func TestListToolsHTTPAndStdio(t *testing.T) {
	var sawAuth, sawSession string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID     *int   `json:"id"`
			Method string `json:"method"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		sawAuth = r.Header.Get("Authorization")
		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", "s1")
		} else {
			sawSession = r.Header.Get("Mcp-Session-Id")
		}
		if req.ID == nil {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		res := `{"protocolVersion":"x"}`
		if req.Method == "tools/list" {
			// Answer this one as an event stream.
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintf(w, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":%d,\"result\":{\"tools\":[{\"name\":\"search\"}]}}\n\n", *req.ID)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%d,"result":%s}`, *req.ID, res)
	}))
	defer srv.Close()
	env := map[string]string{"TOK": "abc"}
	tools, err := ListTools(context.Background(), Server{Name: "x", Kind: "http", URL: srv.URL, BearerEnv: "TOK"}, func(k string) string { return env[k] })
	if err != nil || len(tools) != 1 || tools[0].Name != "search" || sawAuth != "Bearer abc" || sawSession != "s1" {
		t.Fatalf("http: %v %+v auth=%q session=%q", err, tools, sawAuth, sawSession)
	}
	if _, err := ListTools(context.Background(), Server{Kind: "http", URL: srv.URL, BearerEnv: "NOPE"}, func(string) string { return "" }); err == nil {
		t.Error("a missing token variable should fail")
	}
	exe, _ := os.Executable()
	t.Setenv("AFK_FAKE_MCP", "1")
	tools, err = ListTools(context.Background(), Server{Kind: "stdio", Command: exe, Args: []string{"-test.run=^$"}}, nil)
	if err != nil || len(tools) != 2 {
		t.Fatalf("stdio: %v %+v", err, tools)
	}
}
