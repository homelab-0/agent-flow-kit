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
	t.Setenv("AFK_GATEWAY_KEY_ENV", "")
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

func TestConfigGetJSONRefusesNaN(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AFK_CONFIG", "")
	cfg := filepath.Join(home, ".config", "afk", "config.toml")
	if err := os.MkdirAll(filepath.Dir(cfg), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg, []byte("version = 1\nfuture_value = nan\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errb bytes.Buffer
	if code := configCmd([]string{"get", "--json"}, &out, &errb); code != 1 || out.Len() != 0 || !strings.Contains(errb.String(), "JSON") {
		t.Fatalf("%d %q %q", code, out.String(), errb.String())
	}
}

func TestBenchSyncStopsOnInvalidConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AFK_CONFIG", "")
	t.Setenv("AFK_BENCHMARK_FEED_DIR", t.TempDir())
	cfg := filepath.Join(home, ".config", "afk", "config.toml")
	if err := os.MkdirAll(filepath.Dir(cfg), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg, []byte("version = 1\n[route]\nprefer = \"fast\"\n[bench.sources]\nmodelsdev = { enabled = false }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errb bytes.Buffer
	code := benchCmd([]string{"sync", "--json"}, &out, &errb)
	if code != 1 || !strings.Contains(out.String(), `"result":"error"`) || !strings.Contains(out.String(), "route.prefer") {
		t.Fatalf("%d %s %s", code, out.String(), errb.String())
	}
	if _, err := os.Stat(filepath.Join(home, ".config", "afk", "benchmarks.json")); err == nil {
		t.Fatal("the catalog was written despite the invalid config")
	}
}
