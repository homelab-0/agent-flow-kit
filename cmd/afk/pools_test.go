package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/router"
)

func TestPoolsClear(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	sig := filepath.Join(home, "signals.json")
	t.Setenv("AFK_ROUTER_SIGNALS_FILE", sig)
	now := time.Now()
	for _, p := range []string{"anthropic-max", "openai-plus"} {
		if err := router.MarkPoolDegraded(sig, p, "429 Too Many Requests", now); err != nil {
			t.Fatal(err)
		}
	}
	if err := router.MarkModelUnavailable(sig, "old-model", "", now); err != nil {
		t.Fatal(err)
	}

	var out, errb bytes.Buffer
	if rc := poolsCmd([]string{"clear", "anthropic-max", "--dry-run"}, &out, &errb); rc != 0 {
		t.Fatalf("dry run rc %d: %s", rc, errb.String())
	}
	if !strings.Contains(out.String(), "Would clear anthropic-max.") {
		t.Errorf("dry run said %q", out.String())
	}
	if b, _ := os.ReadFile(sig); !strings.Contains(string(b), "anthropic-max") {
		t.Fatal("a dry run changed the file")
	}

	out.Reset()
	if rc := poolsCmd([]string{"clear", "anthropic-max", "--json"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d: %s", rc, errb.String())
	}
	var got struct{ Cleared []string }
	if err := json.Unmarshal(out.Bytes(), &got); err != nil || len(got.Cleared) != 1 || got.Cleared[0] != "anthropic-max" {
		t.Fatalf("json %q %v", out.String(), err)
	}
	b, _ := os.ReadFile(sig)
	if strings.Contains(string(b), "anthropic-max") || !strings.Contains(string(b), "openai-plus") {
		t.Fatalf("only the named pool should go: %s", b)
	}

	out.Reset()
	if rc := poolsCmd([]string{"clear"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if !strings.Contains(out.String(), "Cleared model:old-model, openai-plus.") {
		t.Errorf("clear all said %q", out.String())
	}
	out.Reset()
	poolsCmd([]string{"clear"}, &out, &errb)
	if !strings.Contains(out.String(), "Nothing to clear") {
		t.Errorf("second clear said %q", out.String())
	}
	if rc := poolsCmd([]string{"wipe"}, &out, &errb); rc != 2 {
		t.Errorf("unknown command rc %d", rc)
	}
}

func TestPoolsClearWithNoFile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	sig := filepath.Join(home, "none", "signals.json")
	t.Setenv("AFK_ROUTER_SIGNALS_FILE", sig)
	var out, errb bytes.Buffer
	if rc := poolsCmd([]string{"clear"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d: %s", rc, errb.String())
	}
	if _, err := os.Stat(sig); err == nil {
		t.Error("clearing with no file should not create one")
	}
}

func TestPoolsTextShowsPacing(t *testing.T) {
	now := time.Unix(1795000000, 0)
	used, head := 40.0, 60.0
	reset := now.Add(9 * time.Hour).UTC().Format(time.RFC3339)
	unused := 58.0
	p := &router.Probe{Pools: map[string]router.Pool{
		"openai-plus": {State: "available", UsedPct: &used, HeadroomPct: &head, QuotaSource: "codex_rate_limits", ResetsAt: &reset, Window: "weekly",
			Pacing: &router.Pacing{Window: "weekly", ResetsAt: reset, ElapsedPct: 95, UnusedAtResetPct: &unused, Adjustment: 3.8}},
		"opencode-free": {State: "offline"},
	}}
	got := poolsText(p, now, time.UTC, true)
	// A reading taken a while ago says when.
	old := now.Add(-3 * time.Hour).UTC().Format(time.RFC3339)
	op := p.Pools["openai-plus"]
	op.ObservedAt = &old
	p.Pools["openai-plus"] = op
	if aged := poolsText(p, now, time.UTC, true); !strings.Contains(aged, "60% left, reported by codex 3h ago") {
		t.Errorf("no reading age in\n%s", aged)
	}
	for _, want := range []string{"openai-plus", "60% left, reported by codex", "weekly window resets in 9h with ~58% unused at this rate (routing +3.8)", "opencode-free     offline"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
	if strings.Contains(poolsText(p, now, time.UTC, false), "routing") {
		t.Error("with route.pacing off the routing effect is shown")
	}
}

func TestPoolsJSONIsThePoolsDocument(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("PATH", t.TempDir())
	var out, errb bytes.Buffer
	if code := poolsCmd([]string{"--json"}, &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	var doc struct {
		Schema string                 `json:"schema"`
		Pools  map[string]router.Pool `json:"pools"`
	}
	if err := json.Unmarshal(out.Bytes(), &doc); err != nil || doc.Schema != router.PoolsSchema || len(doc.Pools) == 0 {
		t.Fatalf("%v %q %d pools", err, doc.Schema, len(doc.Pools))
	}
}
