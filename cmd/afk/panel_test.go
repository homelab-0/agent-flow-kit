package main

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
)

func panelCore(t *testing.T) *core.Core {
	t.Helper()
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte("#!/bin/sh\necho 2.1.0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"AFK_LOCAL_ENGINES": "off"}
	getenv := func(k string) string { return env[k] }
	return &core.Core{Home: home, Getenv: getenv, Cwd: home, Now: time.Now,
		Harness:   harness.Env{Home: home, Path: bin, BinDir: bin, OS: runtime.GOOS, Getenv: func(string) string { return "" }},
		Installed: func(h string) bool { return h == "claude" }}
}

func TestPanelSource(t *testing.T) {
	c := panelCore(t)
	s := newPanelSource(c)
	s.discover = func(context.Context) harness.Report {
		return harness.Report{Harnesses: []harness.Info{
			{Name: "codex", Installed: false},
			{Name: "claude", Installed: true, Version: "2.1.0", Auth: harness.AuthOK, UpdateCommand: []string{"claude", "update"}},
		}}
	}
	ctx := context.Background()
	h, err := s.Harnesses(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h.Rows[0].Name != "claude" || h.Rows[0].SignIn != "signed in" || h.Rows[0].Routes != "plan" || h.Rows[0].Update != "claude update" || len(h.Rows[0].Models) == 0 {
		t.Errorf("claude row %+v", h.Rows[0])
	}
	b, err := s.Benchmarks(ctx, "coding")
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Rows) == 0 || b.Rows[0].Via[0].Harness != "claude" || b.Rows[0].Score == nil {
		t.Errorf("bench rows %+v", b.Rows)
	}
	for _, r := range b.Rows {
		if r.Via[0].Harness != "claude" {
			t.Errorf("a model on a CLI that isn't installed: %+v", r)
		}
	}
	if len(b.Routes) == 0 {
		t.Errorf("no effective scores: %s", b.Problems)
	}
	out := "solved"
	if _, err := runrec.Write(runrec.DirFor(c.Home, c.Getenv), runrec.Record{ID: "r-1", StartedAt: runrec.Stamp(time.Now().Add(-time.Hour)), Where: "here",
		Route: engine.Route{Harness: "claude", Model: "sonnet"}, DurationS: 90, Outcome: &out}); err != nil {
		t.Fatal(err)
	}
	st, err := s.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Plans) != 1 || st.Plans[0].Plan != "Claude plan" || len(st.Runs) != 1 || st.Runs[0].Outcome != "solved" || st.Gateway != nil {
		t.Errorf("status %+v", st)
	}
	cv, err := s.Config(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var keys []string
	for _, r := range cv.Rows {
		keys = append(keys, r[0]+"="+r[1])
	}
	if got := strings.Join(keys, " "); !strings.Contains(got, "route.prefer=balanced") || !strings.Contains(got, "local.engines=off") || cv.Exists {
		t.Errorf("config rows %s", got)
	}
}

func TestStatusNeedsATerminal(t *testing.T) {
	var out, errb strings.Builder
	if code := statusCmd([]string{"--tab", "nope"}, &out, &errb); code != 2 {
		t.Errorf("bad tab: %d", code)
	}
}
