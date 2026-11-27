package core

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

func localRoute(u string) engine.Route {
	return engine.Route{Harness: "claude", Model: "qwen3.6:27b", EntitlementPool: "local", CostClass: "local",
		LaunchClass: "claude-local", EngineURL: u, Engine: "ollama", SupportedEfforts: []string{}}
}

// A local route runs claude against the engine with no plan login: its
// own config directory, every vendor variable unset, and every model
// Claude Code asks for set to the local one.
func TestLocalPlan(t *testing.T) {
	c, _ := testCore(t)
	p, err := c.LaunchPlan(context.Background(), localRoute("http://127.0.0.1:11434/"), "interactive", "", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]string{
		"ANTHROPIC_BASE_URL": "http://127.0.0.1:11434", "ANTHROPIC_AUTH_TOKEN": "local",
		"ANTHROPIC_DEFAULT_HAIKU_MODEL": "qwen3.6:27b", "CLAUDE_CODE_SUBAGENT_MODEL": "qwen3.6:27b",
		"CLAUDE_CONFIG_DIR": filepath.Join(c.Home, ".local", "state", "agent-flow-kit", "local-claude"),
	} {
		if p.EnvSet[k] != v {
			t.Errorf("%s = %q, want %q", k, p.EnvSet[k], v)
		}
	}
	if len(p.EnvFrom) != 0 {
		t.Errorf("a local route copies no secret: %v", p.EnvFrom)
	}
	for _, n := range []string{"ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_SOMETHING"} {
		if !slices.Contains(p.EnvUnset, n) {
			t.Errorf("%s is not unset: %v", n, p.EnvUnset)
		}
	}
	for _, n := range p.EnvUnset {
		if _, set := p.EnvSet[n]; set {
			t.Errorf("%s is both set and unset", n)
		}
	}
	argv := strings.Join(p.Argv, " ")
	if !strings.Contains(argv, "--model qwen3.6:27b") || strings.Contains(argv, "--effort") {
		t.Errorf("argv %q", argv)
	}
	for _, bad := range []engine.Route{
		localRoute("http://10.0.0.5:11434"),
		{Harness: "claude", Model: "q", EntitlementPool: "anthropic-max", CostClass: "subscription", LaunchClass: "claude-local", EngineURL: "http://127.0.0.1:1"},
	} {
		_, err := c.LaunchPlan(context.Background(), bad, "interactive", "", nil, "")
		var pe *engine.PlanError
		var ue *UsageError
		if !errors.As(err, &pe) && !errors.As(err, &ue) {
			t.Errorf("%+v was planned: %v", bad, err)
		}
	}
}

// Explain shows each local engine as a row of its own beside the CLIs.
func TestExplainShowsLocalEngines(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/version":
			io.WriteString(w, `{"version":"0.15.0"}`)
		case "/api/tags":
			io.WriteString(w, `{"models":[{"name":"qwen3.6:27b"}]}`)
		case "/api/show":
			io.WriteString(w, `{"capabilities":["completion","tools"]}`)
		case "/api/ps":
			io.WriteString(w, `{"models":[{"name":"qwen3.6:27b"}]}`)
		case "/v1/messages":
			w.WriteHeader(http.StatusBadRequest)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	c, _ := testCore(t)
	c.Live = true
	c.Getenv = func(string) string { return "" }
	cfg := config.PathsFor(c.Home, c.Getenv).Config
	if err := os.MkdirAll(filepath.Dir(cfg), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "version = 1\n\n[local]\nengines = \"off\"\nurls = [\"" + srv.URL + "\"]\ngpu = \"RTX 5090\"\n"
	if err := os.WriteFile(cfg, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var added []string
	ctx := engine.WithProgress(context.Background(), func(p engine.Progress) {
		if p.Kind == "add" {
			added = append(added, p.Harnesses...)
		}
	})
	ex, err := c.Explain(ctx, engine.RouteFlags{Task: "coding"}, "fix the test")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(added, ",") != "ollama" {
		t.Errorf("added %v", added)
	}
	var local, plan *engine.Route
	for i, r := range ex.ByHarness {
		switch {
		case r.IsLocal():
			local = &ex.ByHarness[i]
		case r.Harness == "claude":
			plan = &ex.ByHarness[i]
		}
	}
	if local == nil || local.Model != "qwen3.6:27b" || local.EngineURL != srv.URL || local.EngineGPU != "RTX 5090" || local.EngineState != "loaded" || local.Effort != "" {
		t.Errorf("local row %+v", local)
	}
	if plan == nil {
		t.Error("the claude plan row went missing beside the local one")
	}
}
