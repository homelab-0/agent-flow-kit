package mcp

import (
	"strings"
	"testing"
)

func TestFoundAndImport(t *testing.T) {
	f := newFixture(t, `
[[server]]
name = "known"
url = "https://known.example/mcp"
`)
	f.write(t, ".claude.json", `{"mcpServers": {
  "known": {"type": "http", "url": "https://known.example/mcp"},
  "github": {"type": "http", "url": "https://api.example/mcp", "headers": {"Authorization": "Bearer ${GH_TOKEN}"}},
  "playwright": {"command": "npx", "args": ["@playwright/mcp@latest"], "env": {"API_KEY": "sk-secret"}},
  "old": {"type": "sse", "url": "https://old.example/sse"},
  "keyed": {"type": "http", "url": "https://k.example/mcp?key=abc"}
}}`)
	f.write(t, ".codex/config.toml", `
[mcp_servers.github]
url = "https://api.example/mcp"
bearer_token_env_var = "GH_TOKEN"

[mcp_servers.playwright]
command = "npx"
args = ["@playwright/mcp@1.0"]
`)
	found, err := f.env.Found(f.targets)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Found{}
	for _, x := range found {
		got[x.Name] = x
	}
	if _, ok := got["known"]; ok {
		t.Error("a server mcp.toml lists was offered for import")
	}
	gh := got["github"]
	if gh.Why != "" || gh.Server.BearerEnv != "GH_TOKEN" || strings.Join(gh.In, ",") != "claude,codex" || gh.Differs {
		t.Errorf("github: %+v", gh)
	}
	pw := got["playwright"]
	if pw.Why != "" || !pw.Differs || strings.Join(pw.Server.Env, ",") != "API_KEY" || len(pw.Left) != 1 || !strings.Contains(pw.Left[0], "value is written") {
		t.Errorf("playwright: %+v", pw)
	}
	if strings.Contains(strings.Join(pw.Left, " "), "sk-secret") {
		t.Error("a secret value was read into the report")
	}
	if got["old"].Why == "" || got["keyed"].Why == "" {
		t.Errorf("sse and keyed urls should not import: %+v %+v", got["old"], got["keyed"])
	}
	if pw.Where() != "npx @playwright/mcp@latest" {
		t.Errorf("where %q", pw.Where())
	}

	done, err := f.env.Import(f.targets, nil)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(done, ",") != "github,playwright" {
		t.Errorf("imported %v", done)
	}
	toml := f.read(t, ".config/afk/mcp.toml")
	if !strings.Contains(toml, `name = "github"`) || !strings.Contains(toml, `bearer = "env:GH_TOKEN"`) || strings.Contains(toml, "sk-secret") {
		t.Errorf("mcp.toml:\n%s", toml)
	}
	if again, _ := f.env.Found(f.targets); len(again) != 2 {
		t.Errorf("after import only the two that can't import should be left: %+v", again)
	}
	if _, err := f.env.Import(f.targets, []string{"old"}); err == nil {
		t.Error("importing an sse server by name should fail")
	}
}

func TestImportThenSyncAdoptsDefaults(t *testing.T) {
	f := newFixture(t, "")
	f.write(t, ".claude.json", `{"mcpServers": {"context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}}}`)
	if _, err := f.env.Import(f.targets, nil); err != nil {
		t.Fatal(err)
	}
	st, err := f.env.Scan(f.targets)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range st.Rows {
		if r.Name == "context7" && r.Cells["claude"] != Pending {
			t.Errorf("claude's own context7 without a type should be taken on, got %s", r.Cells["claude"])
		}
	}
}
