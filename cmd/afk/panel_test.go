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
	"github.com/homelab-0/agent-flow-kit/internal/router"
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
	s := newPanelSource(c, "")
	s.discover = func(context.Context) harness.Report {
		return harness.Report{Harnesses: []harness.Info{
			{Name: "codex", Installed: false},
			{Name: "claude", Installed: true, Version: "2.1.0", Auth: harness.AuthOK, AuthChecked: harness.AuthByStatus, UpdateCommand: []string{"claude", "update"}},
			{Name: "grok", Installed: true, Auth: harness.AuthOK, AuthChecked: harness.AuthByFile},
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
	// A login file that is merely there is not "signed in".
	if g := h.Rows[1]; g.Name != "grok" || g.SignIn != "login on disk" || g.Note == "" {
		t.Errorf("grok row %+v", g)
	}
	b, err := s.Benchmarks(ctx, "coding")
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Rows) == 0 || b.Rows[0].Via[0].Harness != "claude" || b.Rows[0].Score == nil {
		t.Errorf("bench rows %+v", b.Rows)
	}
	for _, r := range b.Rows {
		if len(r.Via) == 0 {
			t.Errorf("a row with no route: %+v", r)
		}
		for _, v := range r.Via {
			if v.Harness != "claude" {
				t.Errorf("a model on a CLI that isn't installed: %+v", r)
			}
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

// The Runs tab's plan rows say what the CLI says about its sign-in (never
// "ok" by default), and show a failed run's mark as set aside, with no
// figure, until it is cleared.
func TestStatusSignInAndSetAside(t *testing.T) {
	c := panelCore(t)
	s := newPanelSource(c, "")
	s.discover = func(context.Context) harness.Report {
		return harness.Report{Harnesses: []harness.Info{
			{Name: "claude", Installed: true, Auth: harness.AuthSignedOut, AuthChecked: harness.AuthByStatus},
		}}
	}
	signals := filepath.Join(c.Home, ".config", "afk", "pool-signals.json")
	if err := os.MkdirAll(filepath.Dir(signals), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := router.MarkPoolDegraded(signals, "anthropic-max", "429 rate limit", time.Now()); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	st, err := s.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}
	p := st.Plans[0]
	if p.SignIn != "signed out" || !p.SetAside || p.FiveHour != nil || p.Week != nil ||
		!strings.Contains(p.Note, "rate-limit or quota error") || !strings.Contains(p.Note, "not a usage reading") {
		t.Fatalf("plan row %+v", p)
	}
	msg, err := s.ClearMarks(ctx)
	if err != nil || msg != "Cleared anthropic-max." {
		t.Fatalf("clear: %q %v", msg, err)
	}
	st, err = s.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Plans[0].SetAside {
		t.Fatalf("still set aside after clearing: %+v", st.Plans[0])
	}
	if msg, _ := s.ClearMarks(ctx); msg != "No failed-run mark to clear." {
		t.Fatalf("second clear: %q", msg)
	}
}

func TestPlanLabelAddsOnlyAReportedTier(t *testing.T) {
	for _, c := range []struct{ pid, reported, want string }{
		{"xai-grok", "", "Grok plan"},
		{"anthropic-max", "", "Claude plan"},
		{"openai-plus", "pro", "ChatGPT plan · pro"},
		{"other", "team", "team"},
	} {
		if got := planLabel(c.pid, c.reported); got != c.want {
			t.Errorf("planLabel(%q, %q) = %q, want %q", c.pid, c.reported, got, c.want)
		}
	}
}
