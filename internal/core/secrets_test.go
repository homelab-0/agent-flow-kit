package core

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/launch"
)

func TestOwnSecretsStayOutOfTheCLI(t *testing.T) {
	c, _ := testCore(t)
	env := map[string]string{
		"AFK_GATEWAY_KEY": "legacy", "WORK_KEY": "w", "MINE": "m", "AFK_GATEWAY_KEY_ENV": "MINE",
		"OPENAI_API_KEY": "o", "AFK_LITELLM_BASE_URL": "https://work.example",
	}
	c.Getenv = func(k string) string { return env[k] }
	cfg := filepath.Join(c.Home, ".config", "afk", "config.toml")
	if err := os.MkdirAll(filepath.Dir(cfg), 0o755); err != nil {
		t.Fatal(err)
	}
	// One gateway keeps its key in a plain variable, one in a vendor's own
	// variable (left alone), one in a variable that isn't set.
	body := "version = 1\n[gateway.work]\nurl = \"https://work.example\"\nkey = \"env:WORK_KEY\"\n" +
		"[gateway.oa]\nurl = \"https://oa.example\"\nkey = \"env:OPENAI_API_KEY\"\n" +
		"[gateway.off]\nurl = \"https://off.example\"\nkey = \"env:NOT_SET\"\n"
	if err := os.WriteFile(cfg, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	want := []string{"AFK_GATEWAY_KEY", "MINE", "WORK_KEY"}

	// A plan login launch: the keys go, the vendor's variable stays.
	p, err := c.LaunchPlan(context.Background(), engine.Route{Harness: "codex", Model: "m", LaunchClass: "codex-plan"}, "interactive", "", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(p.EnvUnset, want) {
		t.Fatalf("env_unset = %v, want %v", p.EnvUnset, want)
	}

	// A gateway launch still gets its key, copied before the variable goes.
	g, err := c.LaunchPlan(context.Background(), engine.Route{Harness: "claude", Model: "q", EntitlementPool: "litellm-local", CostClass: "free", LaunchClass: "claude-gateway", LitellmBaseURL: "https://work.example"}, "interactive", "", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	var base []string
	for k, v := range env {
		base = append(base, k+"="+v)
	}
	out, err := launch.BuildEnv(base, g.EnvSet, g.EnvFrom, g.EnvUnset)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(out, "\n") + "\n"
	if !strings.Contains(got, "ANTHROPIC_AUTH_TOKEN=m\n") || !strings.Contains(got, "OPENAI_API_KEY=o\n") {
		t.Fatalf("the launch lost a variable it needs:\n%s", got)
	}
	for _, n := range want {
		if strings.Contains(got, n+"=") {
			t.Fatalf("%s reached the CLI:\n%s", n, got)
		}
	}

	// AFK_KEEP_SECRETS=1 leaves the environment alone.
	env["AFK_KEEP_SECRETS"] = "1"
	p, err = c.LaunchPlan(context.Background(), engine.Route{Harness: "codex", Model: "m", LaunchClass: "codex-plan"}, "interactive", "", nil, "")
	if err != nil || len(p.EnvUnset) != 0 {
		t.Fatalf("kept: %v %v", p.EnvUnset, err)
	}
}
