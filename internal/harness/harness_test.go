package harness

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"
)

func writeExe(t *testing.T, path, script string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func testEnv(t *testing.T) (Env, string) {
	t.Helper()
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	vars := map[string]string{}
	// BinDir keeps discovery inside the fixture: without it Locate would
	// also search the host's /usr/local/bin and friends, and could find
	// (and run) real CLIs.
	return Env{Home: home, Path: bin, BinDir: bin, OS: runtime.GOOS, Getenv: func(k string) string { return vars[k] }}, bin
}

func find(r Report, name string) Info {
	for _, h := range r.Harnesses {
		if h.Name == name {
			return h
		}
	}
	return Info{}
}

func TestRegistryNamesAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, a := range All() {
		if a.Name == "" || a.Display == "" || len(a.Bins) == 0 {
			t.Errorf("incomplete adapter %+v", a)
		}
		for _, n := range append([]string{a.Name}, a.Bins...) {
			if seen[n] && n != a.Name {
				t.Errorf("name %q used twice", n)
			}
			seen[n] = true
		}
	}
}

func TestLookupByBinaryName(t *testing.T) {
	a, ok := Lookup("cursor-agent")
	if !ok || a.Name != "cursor" {
		t.Fatalf("Lookup(cursor-agent) = %v %v", a.Name, ok)
	}
	if _, ok := Lookup("npm"); ok {
		t.Fatal("npm is not a harness")
	}
}

func TestDiscoverInstalledAndMissing(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell scripts")
	}
	e, bin := testEnv(t)
	writeExe(t, filepath.Join(bin, "claude"), `echo "2.1.332 (Claude Code)"`)
	writeExe(t, filepath.Join(bin, "codex"), `echo "codex-cli 0.172.0"`)
	writeFile(t, filepath.Join(e.Home, ".claude", ".credentials.json"), `{"claudeAiOauth":{"accessToken":"x"}}`)

	r := Discover(context.Background(), e, Options{Now: func() time.Time { return time.Unix(0, 0) }})
	if r.Schema != Schema || r.CheckedAt != "1970-01-01T00:00:00Z" {
		t.Fatalf("header %+v", r)
	}
	cl := find(r, "claude")
	if !cl.Installed || !cl.Healthy || cl.Version != "2.1.332" || cl.Auth != AuthOK && runtime.GOOS != "darwin" {
		t.Fatalf("claude %+v", cl)
	}
	cx := find(r, "codex")
	if cx.Version != "0.172.0" || cx.Auth != AuthSignedOut {
		t.Fatalf("codex %+v", cx)
	}
	gm := find(r, "gemini")
	if gm.Installed || gm.Auth != AuthNotInstalled || gm.Binary != "" {
		t.Fatalf("gemini %+v", gm)
	}
	if got := len(r.Installed()); got != 2 {
		t.Fatalf("installed = %d", got)
	}
}

func TestBrokenAndHangingBinaries(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell scripts")
	}
	e, bin := testEnv(t)
	writeExe(t, filepath.Join(bin, "grok"), `echo "Error: missing module" >&2; exit 3`)
	writeExe(t, filepath.Join(bin, "kimi"), `sleep 30`)
	start := time.Now()
	r := Discover(context.Background(), e, Options{VersionTimeout: 300 * time.Millisecond})
	if time.Since(start) > 5*time.Second {
		t.Fatalf("a hanging CLI held discovery for %s", time.Since(start))
	}
	g := find(r, "grok")
	if g.Healthy || g.Problem != "--version failed: Error: missing module" {
		t.Fatalf("grok %+v", g)
	}
	k := find(r, "kimi")
	if k.Healthy || k.Problem == "" || k.Auth != AuthUnknown {
		t.Fatalf("kimi %+v", k)
	}
}

func TestSkipVersionRunsNothing(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell scripts")
	}
	e, bin := testEnv(t)
	marker := filepath.Join(e.Home, "ran")
	writeExe(t, filepath.Join(bin, "codex"), "touch "+marker)
	r := Discover(context.Background(), e, Options{SkipVersion: true})
	if !find(r, "codex").Installed {
		t.Fatal("codex not found")
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("SkipVersion ran the CLI")
	}
}

func TestBinDirIsTheOnlyPlaceLooked(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell scripts")
	}
	e, bin := testEnv(t)
	writeExe(t, filepath.Join(bin, "claude"), "true")
	e.BinDir = filepath.Join(e.Home, "empty")
	if p := Locate(e, mustLookup(t, "claude")); p != "" {
		t.Fatalf("found %s outside BinDir", p)
	}
}

func TestLocateFallsBackToInstallDirs(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell scripts")
	}
	e, _ := testEnv(t)
	e.BinDir = ""
	saved := systemDirs
	systemDirs = nil // only the fixture's PATH and home dirs
	t.Cleanup(func() { systemDirs = saved })
	want := filepath.Join(e.Home, ".local", "bin", "opencode")
	writeExe(t, want, "true")
	if p := Locate(e, mustLookup(t, "opencode")); p != want {
		t.Fatalf("Locate = %q, want %q", p, want)
	}
	// A file without the execute bit is not a CLI.
	writeFile(t, filepath.Join(e.Path, "codex"), "x")
	if p := Locate(e, mustLookup(t, "codex")); p != "" {
		t.Fatalf("non-executable found: %s", p)
	}
}

func mustLookup(t *testing.T, n string) Adapter {
	t.Helper()
	a, ok := Lookup(n)
	if !ok {
		t.Fatalf("no adapter %s", n)
	}
	return a
}

func TestClassify(t *testing.T) {
	cases := []struct {
		name, bin, resolved, method, pkg string
		update                           []string
	}{
		{"claude", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js",
			"npm", "@anthropic-ai/claude-code", []string{"npm", "install", "-g", "@anthropic-ai/claude-code@latest"}},
		{"opencode", "/h/.local/share/mise/installs/opencode/latest/node_modules/.bin/opencode", "/h/.local/share/mise/installs/opencode/2.4.2/node_modules/.bin/opencode",
			"mise", "opencode", []string{"mise", "upgrade", "opencode"}},
		{"claude", "/h/.local/share/mise/command-wrappers/bin/claude", "/usr/bin/mise",
			"mise", "", nil},
		{"claude", "/opt/homebrew/bin/claude", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
			"npm", "@anthropic-ai/claude-code", []string{"npm", "install", "-g", "@anthropic-ai/claude-code@latest"}},
		{"codex", "/opt/homebrew/bin/codex", "/opt/homebrew/Caskroom/codex/0.1/codex",
			"homebrew", "codex", []string{"brew", "upgrade", "codex"}},
		{"gemini", "/h/.bun/bin/gemini", "/h/.bun/install/global/node_modules/@google/gemini-cli/dist/index.js",
			"bun", "@google/gemini-cli", []string{"bun", "add", "-g", "@google/gemini-cli@latest"}},
		{"qwen", "/h/.local/share/pnpm/qwen", "/h/.local/share/pnpm/global/5/node_modules/@qwen-code/qwen-code/cli.js",
			"pnpm", "@qwen-code/qwen-code", []string{"pnpm", "add", "-g", "@qwen-code/qwen-code@latest"}},
		{"devin", "/h/.cargo/bin/devin", "/h/.cargo/bin/devin", "cargo", "devin", []string{"cargo", "install", "devin"}},
		{"claude", "/h/.local/bin/claude", "/h/.local/share/claude/versions/2.1.0", "self-managed", "", []string{"/h/.local/bin/claude", "update"}},
		{"kiro", "/h/.local/bin/kiro-cli", "/h/.local/bin/kiro-cli", "self-managed", "", nil},
	}
	for _, c := range cases {
		m, p, u := classify(mustLookup(t, c.name), c.bin, c.resolved)
		if m != c.method || p != c.pkg || !reflect.DeepEqual(u, c.update) {
			t.Errorf("%s %s: got %s %q %q, want %s %q %q", c.name, c.resolved, m, p, u, c.method, c.pkg, c.update)
		}
	}
}

func TestAuthChecksNeverNeedTokenValues(t *testing.T) {
	e, _ := testEnv(t)
	e.OS = "linux"
	// Empty login files are signed out. Only their size is looked at.
	writeFile(t, filepath.Join(e.Home, ".claude", ".credentials.json"), ``)
	writeFile(t, filepath.Join(e.Home, ".grok", "auth.json"), ``)
	if st, _ := claudeAuth(e); st != AuthSignedOut {
		t.Errorf("claude empty = %s", st)
	}
	if st, _ := mustLookup(t, "grok").auth(e); st != AuthSignedOut {
		t.Errorf("grok empty = %s", st)
	}
	// macOS keeps Claude's login in the Keychain.
	_ = os.Remove(filepath.Join(e.Home, ".claude", ".credentials.json"))
	e.OS = "darwin"
	if st, _ := claudeAuth(e); st != AuthUnknown {
		t.Errorf("claude darwin = %s", st)
	}
	// An API key variable counts for Gemini; its absence is unknown, not signed out.
	g := mustLookup(t, "gemini")
	if st, _ := g.auth(e); st != AuthUnknown {
		t.Errorf("gemini none = %s", st)
	}
	e.Getenv = func(k string) string {
		if k == "GEMINI_API_KEY" {
			return "set"
		}
		return ""
	}
	if st, note := g.auth(e); st != AuthOK || note != "GEMINI_API_KEY is set" {
		t.Errorf("gemini key = %s %q", st, note)
	}
	// CODEX_HOME is honoured.
	ch := filepath.Join(e.Home, "cx")
	writeFile(t, filepath.Join(ch, "auth.json"), `{"tokens":{"account_id":"a"}}`)
	e.Getenv = func(k string) string {
		if k == "CODEX_HOME" {
			return ch
		}
		return ""
	}
	if st, _ := codexAuth(e); st != AuthOK {
		t.Errorf("codex CODEX_HOME = %s", st)
	}
}

func TestReportJSONShape(t *testing.T) {
	e, _ := testEnv(t)
	r := Discover(context.Background(), e, Options{SkipVersion: true})
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	var back struct {
		Schema    string           `json:"schema"`
		Harnesses []map[string]any `json:"harnesses"`
	}
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if back.Schema != Schema || len(back.Harnesses) != len(All()) {
		t.Fatalf("schema %s, %d harnesses", back.Schema, len(back.Harnesses))
	}
	for _, h := range back.Harnesses {
		if _, ok := h["efforts"].([]any); !ok {
			t.Errorf("%v: efforts must be an array, even when empty", h["name"])
		}
	}
}

func TestClaudeConfigDirIsTheOnlyLoginLooked(t *testing.T) {
	e, _ := testEnv(t)
	e.OS = "linux"
	writeFile(t, filepath.Join(e.Home, ".claude", ".credentials.json"), `{"claudeAiOauth":{"accessToken":"x"}}`)
	sel := filepath.Join(e.Home, "other")
	if err := os.MkdirAll(sel, 0o755); err != nil {
		t.Fatal(err)
	}
	e.Getenv = func(k string) string {
		if k == "CLAUDE_CONFIG_DIR" {
			return sel
		}
		return ""
	}
	if st, _ := claudeAuth(e); st != AuthSignedOut {
		t.Fatalf("auth = %s, want signed_out from the selected dir only", st)
	}
	writeFile(t, filepath.Join(sel, ".credentials.json"), `{"claudeAiOauth":{"refreshToken":"y"}}`)
	if st, _ := claudeAuth(e); st != AuthOK {
		t.Fatalf("auth = %s, want authenticated", st)
	}
}

// AFK never opens a login file: one it can't read still counts as signed
// in, and what is inside never matters, only whether anything is.
func TestLoginFilesAreNeverOpened(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("needs file permissions that root ignores")
	}
	e, _ := testEnv(t)
	e.OS = "linux"
	for _, c := range []struct {
		name string
		path []string
	}{
		{"claude", []string{".claude", ".credentials.json"}},
		{"codex", []string{".codex", "auth.json"}},
		{"grok", []string{".grok", "auth.json"}},
		{"pi", []string{".pi", "agent", "auth.json"}},
		{"devin", []string{".local", "share", "devin", "credentials.toml"}},
	} {
		p := filepath.Join(append([]string{e.Home}, c.path...)...)
		writeFile(t, p, `{not json`)
		if err := os.Chmod(p, 0); err != nil {
			t.Fatal(err)
		}
		if st, _ := mustLookup(t, c.name).auth(e); st != AuthOK {
			t.Errorf("%s: auth = %s for an unreadable, malformed login file; want authenticated", c.name, st)
		}
	}
}

func TestEmptyLoginIsSignedOut(t *testing.T) {
	e, _ := testEnv(t)
	e.OS = "linux"
	p := filepath.Join(e.Home, ".codex", "auth.json")
	for _, body := range []string{``, `{}`, "{}\n"} {
		writeFile(t, p, body)
		if st, _ := codexAuth(e); st != AuthSignedOut {
			t.Fatalf("%q: auth = %s, want signed_out", body, st)
		}
	}
}

func TestClassifyCodexLogin(t *testing.T) {
	for out, want := range map[string]string{
		"Logged in using ChatGPT\n":                 "chatgpt",
		"Logged in using an API key - sk-***abcd\n": "apikey",
		"Not logged in\n":                           "",
		"error: unknown command\n":                  "",
	} {
		if got := ClassifyCodexLogin(out); got != want {
			t.Errorf("%q: %q, want %q", out, got, want)
		}
	}
}

func TestLocateReturnsAbsolutePath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell scripts")
	}
	e, bin := testEnv(t)
	writeExe(t, filepath.Join(bin, "claude"), "echo 1.0.0")
	t.Chdir(bin)
	e.BinDir = "."
	p := Locate(e, mustLookup(t, "claude"))
	if !filepath.IsAbs(p) || filepath.Base(p) != "claude" {
		t.Fatalf("Locate = %q, want an absolute path", p)
	}
}

func TestCapWriterBoundsOutput(t *testing.T) {
	w := &capWriter{max: 8}
	for i := 0; i < 1000; i++ {
		if n, err := w.Write([]byte("0123456789")); n != 10 || err != nil {
			t.Fatalf("Write = %d, %v", n, err)
		}
	}
	if got := w.String(); got != "01234567" {
		t.Fatalf("kept %q", got)
	}
}

// Gemini and Qwen follow the same file rule: an empty {} is not a login,
// an API key variable still is, and nothing found is unknown.
func TestFileOrEnvUsesTheLoginSizeRule(t *testing.T) {
	e, _ := testEnv(t)
	e.OS = "linux"
	for _, c := range []struct{ name, file, key string }{
		{"gemini", filepath.Join(".gemini", "oauth_creds.json"), "GEMINI_API_KEY"},
		{"qwen", filepath.Join(".qwen", "oauth_creds.json"), "DASHSCOPE_API_KEY"},
	} {
		a := mustLookup(t, c.name)
		p := filepath.Join(e.Home, c.file)
		writeFile(t, p, `{}`)
		if st, _ := a.auth(e); st != AuthUnknown {
			t.Errorf("%s with {}: %s, want unknown", c.name, st)
		}
		writeFile(t, p, `{"access_token":"x","refresh_token":"y"}`)
		if st, _ := a.auth(e); st != AuthOK {
			t.Errorf("%s with a login: %s", c.name, st)
		}
		_ = os.Remove(p)
		env := e
		env.Getenv = func(k string) string {
			if k == c.key {
				return "set"
			}
			return ""
		}
		if st, _ := a.auth(env); st != AuthOK {
			t.Errorf("%s with %s: %s", c.name, c.key, st)
		}
	}
}
