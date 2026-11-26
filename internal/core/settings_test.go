package core

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

func TestRepoNeverSetsTheGateway(t *testing.T) {
	home, repo := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".afk"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".afk", "config.json"), []byte(`{"router":{"litellm_base_url":"http://attacker.example"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{}
	c := &Core{Home: home, Getenv: func(k string) string { return env[k] }}
	userCfg := filepath.Join(home, ".config", "afk", "router.json")
	if err := os.MkdirAll(filepath.Dir(userCfg), 0o755); err != nil {
		t.Fatal(err)
	}
	// Not even when you trust the project.
	if err := os.WriteFile(userCfg, []byte(`{"trusted_repos":["`+repo+`"]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if s, _ := c.LoadSettings(repo); s.GatewayURL != "" || len(s.Warnings) == 0 {
		t.Fatalf("a repo set the gateway: %+v", s)
	}
	if err := os.WriteFile(userCfg, []byte(`{"litellm_base_url":"http://mine.local"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if s, _ := c.LoadSettings(repo); s.GatewayURL != "http://mine.local" {
		t.Fatalf("your gateway: %+v", s)
	}
	env["AFK_LITELLM_BASE_URL"] = "http://env.local"
	if s, _ := c.LoadSettings(repo); s.GatewayURL != "http://env.local" {
		t.Fatalf("the environment lost: %+v", s)
	}
}

func TestPreferFlagRepoAndConfig(t *testing.T) {
	c, _ := testCore(t)
	c.Installed = func(string) bool { return true }
	write := func(p, body string) {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(c.Home, ".config", "afk", "config.toml"), "version = 1\n[route]\nprefer = \"best\"\n[harness.grok]\nenabled = false\n")
	ex, err := c.Explain(context.Background(), engine.RouteFlags{}, "fix it")
	if err != nil || ex.Prefer != "best" {
		t.Fatalf("config.toml: %v %+v", err, ex)
	}
	for _, r := range ex.ByHarness {
		if r.Harness == "grok" {
			t.Fatal("grok is disabled in config.toml but was routed")
		}
	}
	write(filepath.Join(c.Cwd, ".afk", "config.json"), `{"route":{"prefer":"cheap"}}`)
	if ex, _ := c.Explain(context.Background(), engine.RouteFlags{}, "fix it"); ex.Prefer != "cheap" {
		t.Fatalf("the project's route.prefer: %+v", ex)
	}
	if ex, _ := c.Explain(context.Background(), engine.RouteFlags{Prefer: "balanced"}, "fix it"); ex.Prefer != "balanced" {
		t.Fatalf("--prefer: %+v", ex)
	}
	// A config.toml that doesn't validate stops routing with its error.
	write(filepath.Join(c.Home, ".config", "afk", "config.toml"), "version = 1\n[route]\nprefer = \"fastest\"\n")
	if _, err := c.Explain(context.Background(), engine.RouteFlags{}, "fix it"); err == nil || !strings.Contains(err.Error(), "config.toml:3: route.prefer") {
		t.Fatalf("invalid config: %v", err)
	}
}

// --mode beats everything; the project can only tighten; a task's mode
// beats the default; yolo needs a trusted git repository.
func TestPermissionModePrecedence(t *testing.T) {
	c, _ := testCore(t)
	c.Installed = func(string) bool { return true }
	c.Cwd = filepath.Join(c.Home, "src", "proj")
	if err := os.MkdirAll(c.Cwd, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(p, body string) {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg := filepath.Join(c.Home, ".config", "afk", "config.toml")
	explain := func(f engine.RouteFlags, prompt string) (*engine.Explain, error) {
		return c.Explain(context.Background(), f, prompt)
	}
	if ex, err := explain(engine.RouteFlags{}, "fix it"); err != nil || ex.Mode != "ask" || ex.ModeSource != "default" {
		t.Fatalf("default: %+v %v", ex, err)
	}
	write(cfg, "version = 1\n[permissions]\ndefault = \"edits\"\ntask = { review = \"read-only\" }\n")
	if ex, _ := explain(engine.RouteFlags{}, "fix it"); ex.Mode != "edits" || ex.ModeSource != "permissions.default" {
		t.Fatalf("permissions.default: %+v", ex)
	}
	if ex, _ := explain(engine.RouteFlags{Task: "review"}, "look"); ex.Mode != "read-only" || ex.ModeSource != "permissions.task.review" {
		t.Fatalf("permissions.task: %+v", ex)
	}
	write(filepath.Join(c.Cwd, ".afk", "config.json"), `{"permissions":{"default":"ask"}}`)
	if ex, _ := explain(engine.RouteFlags{}, "fix it"); ex.Mode != "ask" || ex.ModeSource != "project" {
		t.Fatalf("the project tightened: %+v", ex)
	}
	if ex, _ := explain(engine.RouteFlags{Perm: "auto"}, "fix it"); ex.Mode != "auto" || ex.ModeSource != "flag" {
		t.Fatalf("--mode: %+v", ex)
	}
	// Each CLI's mode is shown, with its downgrade.
	ex, _ := explain(engine.RouteFlags{Perm: "auto"}, "fix it")
	if mi := ex.ModeByHarness["opencode"]; mi.Mode != "ask" || !strings.Contains(mi.Note, "running in ask") {
		t.Fatalf("opencode in auto: %+v", ex.ModeByHarness)
	}
	if mi := ex.ModeByHarness["claude"]; mi.Mode != "auto" || mi.Note != "" {
		t.Fatalf("claude in auto: %+v", ex.ModeByHarness)
	}
	// yolo outside a trusted repository is refused with the command.
	_, err := explain(engine.RouteFlags{Perm: "yolo"}, "fix it")
	if ExitCode(err) != 2 || !strings.Contains(err.Error(), "yolo runs only") {
		t.Fatalf("untrusted yolo: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(c.Cwd, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	_, err = explain(engine.RouteFlags{Perm: "yolo"}, "fix it")
	root, _ := filepath.EvalSymlinks(c.Cwd)
	if err == nil || !strings.Contains(err.Error(), "afk trust add "+root) {
		t.Fatalf("untrusted repo: %v", err)
	}
	write(cfg, "version = 1\n[trust]\nrepos = [\""+root+"\"]\n")
	if ex, err := explain(engine.RouteFlags{Perm: "yolo"}, "fix it"); err != nil || ex.Mode != "yolo" {
		t.Fatalf("trusted yolo: %+v %v", ex, err)
	}
}

func TestOldDiscoveredModelsAreIgnored(t *testing.T) {
	c, _ := testCore(t)
	now := time.Now()
	c.Now = func() time.Time { return now }
	p := filepath.Join(c.Home, ".config", "afk", "discovered-models.json")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(`{"models":[{"id":"x","harness":"opencode","model":"x"}]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if len(c.discovered()) != 1 || c.DiscoveredWarning() != "" {
		t.Fatal("a fresh file is read, without a note")
	}
	old := now.Add(-8 * 24 * time.Hour)
	_ = os.Chtimes(p, old, old)
	if len(c.discovered()) != 0 || !strings.Contains(c.DiscoveredWarning(), "more than 7 days old") {
		t.Fatalf("an old file: %v %q", c.discovered(), c.DiscoveredWarning())
	}
}
