package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigCommands(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AFK_CONFIG", "")
	t.Setenv("AFK_GATEWAY_KEY", "sk-must-never-show")
	t.Setenv("AFK_LITELLM_BASE_URL", "http://gw.local:4000")
	t.Chdir(t.TempDir())
	run := func(args ...string) (int, string, string) {
		var out, errb bytes.Buffer
		code := configCmd(args, &out, &errb)
		return code, out.String(), errb.String()
	}
	code, out, _ := run("migrate", "--dry-run", "--json")
	if code != 0 || strings.Contains(out, "sk-must-never-show") || !strings.Contains(out, `env:AFK_GATEWAY_KEY`) {
		t.Fatalf("migrate --dry-run --json: %d %s", code, out)
	}
	cfg := filepath.Join(home, ".config", "afk", "config.toml")
	if _, err := os.Stat(cfg); err == nil {
		t.Fatal("a dry run wrote config.toml")
	}
	if code, _, errs := run("migrate"); code != 0 {
		t.Fatalf("migrate: %s", errs)
	}
	if code, _, errs := run("set", "route.prefer", "cheap"); code != 0 {
		t.Fatalf("set: %s", errs)
	}
	code, out, _ = run("get", "route.prefer", "--json")
	var got map[string]any
	_ = json.Unmarshal([]byte(out), &got)
	if code != 0 || got["value"] != "cheap" || got["source"] != "config.toml" {
		t.Fatalf("get: %s", out)
	}
	code, out, _ = run("get", "--json")
	if code != 0 || strings.Contains(out, "sk-must-never-show") || !strings.Contains(out, "env:AFK_GATEWAY_KEY") {
		t.Fatalf("get --json: %s", out)
	}
	if code, out, _ := run("get", "route.prefer_free"); code != 0 || strings.TrimSpace(out) != "false" {
		t.Fatalf("a default: %d %q", code, out)
	}
	if code, _, _ := run("get", "route.nope"); code != 2 {
		t.Fatal("an unknown key is a usage error")
	}
	if code, _, errs := run("set", "gateway.default.key", "sk-must-never-show"); code == 0 || strings.Contains(errs, "sk-must-never-show") {
		t.Fatalf("a raw key was accepted or echoed: %s", errs)
	}
	if code, out, _ := run("path", "--json"); code != 0 || !strings.Contains(out, `"config_exists":true`) {
		t.Fatalf("path: %s", out)
	}
	if code, _, _ := run("set", "route.prefer"); code != 2 {
		t.Fatal("set needs two words")
	}
	if code, _, _ := run("bogus"); code != 2 {
		t.Fatal("unknown subcommand")
	}
	b, _ := os.ReadFile(cfg)
	if strings.Contains(string(b), "sk-must-never-show") {
		t.Fatal("the secret reached config.toml")
	}
}
