package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
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
