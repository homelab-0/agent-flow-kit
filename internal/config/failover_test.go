package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFailoverSettingIsYours(t *testing.T) {
	home := t.TempDir()
	repo := t.TempDir()
	env := map[string]string{}
	e := Env{Home: home, Repo: repo, Getenv: func(k string) string { return env[k] }}
	load := func() Settings {
		t.Helper()
		s, err := Resolve(e)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	if s := load(); s.Failover != "any" {
		t.Fatalf("default %q", s.Failover)
	}
	cfg := PathsFor(home, e.Getenv).Config
	if err := os.MkdirAll(filepath.Dir(cfg), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg, []byte("version = 1\n[route]\nfailover = \"same-pool\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if s := load(); s.Failover != "same-pool" {
		t.Fatalf("config %q", s.Failover)
	}
	// A repository can't change it.
	if err := os.MkdirAll(filepath.Join(repo, ".afk"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".afk", "config.json"), []byte(`{"route":{"failover":"any"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if s := load(); s.Failover != "same-pool" || len(s.Warnings) == 0 {
		t.Fatalf("repo: %q %v", s.Failover, s.Warnings)
	}
	// The environment wins; a value it doesn't know is ignored.
	env["AFK_ROUTER_FAILOVER"] = "none"
	if s := load(); s.Failover != "none" {
		t.Fatalf("env %q", s.Failover)
	}
	env["AFK_ROUTER_FAILOVER"] = "sometimes"
	if s := load(); s.Failover != "same-pool" {
		t.Fatalf("bad env %q", s.Failover)
	}
}
