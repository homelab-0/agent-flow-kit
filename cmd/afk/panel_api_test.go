package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/apikey"
)

// The API tab does what afk keys does: make, change, rotate, revoke and
// delete, with the key itself returned once and never stored.
func TestPanelAPIKeys(t *testing.T) {
	c := panelCore(t)
	s := newPanelSource(c, "")
	ctx := context.Background()
	v, err := s.API(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(v.Keys) != 0 || v.Server.Running || v.Server.Listen != "127.0.0.1:8484" || v.Server.Open || v.PlanRuns || v.PlanWarning == "" {
		t.Fatalf("empty view %+v", v)
	}
	if v.Kinds[0].ID != "router" || len(v.Kinds[0].Warning) != 0 || len(v.Kinds) < 2 {
		t.Fatalf("kinds %+v", v.Kinds)
	}
	// A key for one CLI carries the vendor-terms note, and says it won't
	// answer while sign-ins are off.
	var grok []string
	for _, k := range v.Kinds {
		if k.ID == "grok" {
			grok = k.Warning
		}
	}
	if w := strings.Join(grok, "\n"); !strings.Contains(w, "terms decide") || !strings.Contains(w, "won't answer until") {
		t.Fatalf("grok warning %q", w)
	}

	res, err := s.APIDo(ctx, "add", "LiteLLM", "router")
	if err != nil || !apikey.LooksLikeKey(res.Secret) || res.Name != "litellm" {
		t.Fatalf("add: %+v %v", res, err)
	}
	if use := strings.Join(res.Lines, "\n"); !strings.Contains(use, "http://127.0.0.1:8484/v1") || !strings.Contains(use, "afk/auto") || !strings.Contains(use, "server is stopped") {
		t.Fatalf("how to use it: %q", use)
	}
	store, _ := s.apiStore()
	if b, _ := os.ReadFile(store.Path); strings.Contains(string(b), res.Secret) {
		t.Fatal("the key itself was stored")
	}
	if _, err := s.APIDo(ctx, "add", "g", "grok"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.APIDo(ctx, "add", "bad", "nope"); err == nil {
		t.Fatal("a key for a CLI AFK doesn't run")
	}

	dir := t.TempDir()
	for _, set := range [][]string{{"litellm", "per-minute", "30"}, {"litellm", "per-day", "off"}, {"g", "models", "grok-4, grok-code"}, {"g", "dir", dir}, {"g", "mode", "edits"}} {
		if _, err := s.APIDo(ctx, "set", set...); err != nil {
			t.Fatalf("set %v: %v", set, err)
		}
	}
	for _, bad := range [][]string{{"litellm", "per-minute", "many"}, {"litellm", "mode", "edits"}, {"litellm", "models", "x"}, {"g", "dir", filepath.Join(dir, "missing")}} {
		if _, err := s.APIDo(ctx, "set", bad...); err == nil {
			t.Errorf("set %v was taken", bad)
		}
	}
	v, _ = s.API(ctx)
	g, r := v.Keys[0], v.Keys[1] // listed by name
	if r.PerMinute != 30 || r.PerDay != 0 || r.Concurrent != 2 || r.Kind != "router" || r.Asks == "" {
		t.Errorf("router row %+v", r)
	}
	if g.Display != "Grok CLI" || len(g.Models) != 2 || g.Dir != dir || g.Mode != "edits" || g.PerMinute != 6 {
		t.Errorf("harness row %+v", g)
	}
	// Taking the folder away takes the mode with it.
	if _, err := s.APIDo(ctx, "set", "g", "dir", "none"); err != nil {
		t.Fatal(err)
	}
	if k, _ := store.Get("g"); k.Dir != "" || k.Mode != "" {
		t.Errorf("after none: %+v", k)
	}

	rot, err := s.APIDo(ctx, "rotate", "litellm")
	if err != nil || rot.Secret == res.Secret || !apikey.LooksLikeKey(rot.Secret) {
		t.Fatalf("rotate: %+v %v", rot, err)
	}
	if _, ok := store.Verify(res.Secret); ok {
		t.Error("the old secret still works")
	}
	if _, err := s.APIDo(ctx, "revoke", "litellm"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.APIDo(ctx, "rm", "g"); err != nil {
		t.Fatal(err)
	}
	v, _ = s.API(ctx)
	if len(v.Keys) != 1 || !v.Keys[0].Revoked {
		t.Fatalf("after revoke and rm: %+v", v.Keys)
	}
	if res, err := s.APIDo(ctx, "serve-stop"); err != nil || res.Text != "afk serve is not running." {
		t.Fatalf("stop with nothing running: %+v %v", res, err)
	}
}

func TestListenOpen(t *testing.T) {
	for addr, want := range map[string]bool{"127.0.0.1:8484": false, "localhost:8484": false, "[::1]:8484": false, "0.0.0.0:8484": true, "192.168.1.5:8484": true, ":8484": true} {
		if got := listenOpen(addr); got != want {
			t.Errorf("%s: %v", addr, got)
		}
	}
}
