package main

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestKeysCommand(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_STATE_HOME", "")
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AFK_CONFIG", "")
	t.Setenv("AFK_KEYS_FILE", filepath.Join(home, "keys.json"))
	run := func(args ...string) (int, string, string) {
		var out, errb bytes.Buffer
		code := keysCmd(args, &out, &errb)
		return code, out.String(), errb.String()
	}
	if code, out, _ := run(); code != 0 || !strings.Contains(out, "No keys yet") {
		t.Fatalf("empty list: %d %q", code, out)
	}
	// The key alone goes to stdout, so it can be captured.
	code, out, errs := run("add", "gw")
	token := strings.TrimSpace(out)
	if code != 0 || !strings.HasPrefix(token, "afk_") || strings.Contains(token, "\n") || !strings.Contains(errs, "only time it is shown") {
		t.Fatalf("add: %d %q %q", code, out, errs)
	}
	// A harness key carries the note about the vendor's terms, and says
	// it won't answer while plan runs are off.
	code, _, errs = run("add", "my-grok", "--harness", "grok", "--per-day=50", "--models", "grok-5, grok-code")
	if code != 0 || !strings.Contains(errs, "xAI's terms") || !strings.Contains(errs, "sharing one subscription") || !strings.Contains(errs, "serve.plan_runs") {
		t.Fatalf("harness add: %d %q", code, errs)
	}
	if code, _, errs := run("add", "bad", "--harness", "notacli"); code == 0 || !strings.Contains(errs, "not a CLI AFK runs") {
		t.Errorf("unknown harness: %d %q", code, errs)
	}
	if code, _, _ := run("add", "gw"); code == 0 {
		t.Error("a second key with one name")
	}
	code, out, _ = run("--json")
	var list struct {
		Keys []struct {
			Name, Kind, Harness string
			Models              []string
			Limits              struct {
				PerMinute  int `json:"per_minute"`
				PerDay     int `json:"per_day"`
				Concurrent int `json:"concurrent"`
			}
		}
	}
	if err := json.Unmarshal([]byte(out), &list); err != nil || code != 0 || len(list.Keys) != 2 {
		t.Fatalf("list: %d %s %v", code, out, err)
	}
	if strings.Contains(out, token[strings.LastIndex(token, "_")+1:]) {
		t.Error("the list shows a secret")
	}
	g := list.Keys[1]
	if g.Name != "my-grok" || g.Harness != "grok" || g.Limits.PerDay != 50 || g.Limits.PerMinute != 6 || len(g.Models) != 2 {
		t.Errorf("harness key %+v", g)
	}
	if code, out, _ := run("set", "my-grok", "--no-limits", "--per-minute", "3"); code != 0 || !strings.Contains(out, "3 /min · no /day limit · no at once limit") {
		t.Errorf("set: %d %q", code, out)
	}
	if code, _, _ := run("set", "my-grok"); code != 2 {
		t.Errorf("set with nothing: %d", code)
	}
	if code, out, _ := run("rotate", "gw"); code != 0 || strings.TrimSpace(out) == token {
		t.Errorf("rotate: %d %q", code, out)
	}
	if code, out, _ := run("revoke", "gw"); code != 0 || !strings.Contains(out, "Revoked gw") {
		t.Errorf("revoke: %d %q", code, out)
	}
	if code, out, _ := run(); code != 0 || !strings.Contains(out, "REVOKED") {
		t.Errorf("list after revoke: %d %q", code, out)
	}
	if code, _, _ := run("rm", "gw"); code != 0 {
		t.Errorf("rm: %d", code)
	}
	if code, _, _ := run("rm", "gw"); code == 0 {
		t.Error("rm of a missing key")
	}
	if code, _, _ := run("add", "x", "--bogus"); code != 2 {
		t.Errorf("unknown option: %d", code)
	}
}

func TestServeBanner(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("AFK_KEYS_FILE", filepath.Join(home, "keys.json"))
	store, _ := keysEnv()
	local := strings.Join(serveBanner("127.0.0.1:8484", store, false), "\n")
	if !strings.Contains(local, "none yet") || !strings.Contains(local, "serve.plan_runs true") || strings.Contains(local, "plain HTTP") {
		t.Errorf("local banner:\n%s", local)
	}
	wide := strings.Join(serveBanner("0.0.0.0:8484", store, true), "\n")
	if !strings.Contains(wide, "plain HTTP") || !strings.Contains(wide, "may answer calls") {
		t.Errorf("wide banner:\n%s", wide)
	}
}
