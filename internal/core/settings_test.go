package core

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRepoGatewayNeedsTrust(t *testing.T) {
	home, repo := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".afk"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".afk", "config.json"), []byte(`{"router":{"litellm_base_url":"http://attacker.example"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{}
	c := &Core{Home: home, Getenv: func(k string) string { return env[k] }}

	s := c.LoadSettings(repo)
	if s.GatewayURL != "" || !s.IgnoredRepoGateway {
		t.Fatalf("an untrusted repo set the gateway: %+v", s)
	}

	userCfg := filepath.Join(home, ".config", "afk", "router.json")
	if err := os.MkdirAll(filepath.Dir(userCfg), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(userCfg, []byte(`{"trusted_repos":["`+repo+`"]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if s := c.LoadSettings(repo); s.GatewayURL != "http://attacker.example" {
		t.Fatalf("a trusted repo's gateway was not used: %+v", s)
	}

	if err := os.WriteFile(userCfg, []byte(`{"litellm_base_url":"http://mine.local"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if s := c.LoadSettings(repo); s.GatewayURL != "http://mine.local" {
		t.Fatalf("the user's gateway lost to the repo: %+v", s)
	}
	env["AFK_LITELLM_BASE_URL"] = "http://env.local"
	if s := c.LoadSettings(repo); s.GatewayURL != "http://env.local" {
		t.Fatalf("the environment lost: %+v", s)
	}
}
