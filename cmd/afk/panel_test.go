package main

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/router"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
	"github.com/homelab-0/agent-flow-kit/internal/tui"
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

// The Usage tab's plan rows say what the CLI says about its sign-in (never
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

// The Config tab writes settings itself: a choice or a typed value goes
// to config.toml, and a bad value is refused without touching the file.
func TestConfigSetFromTheTab(t *testing.T) {
	c := panelCore(t)
	s := newPanelSource(c, "")
	ctx := context.Background()
	v, err := s.Config(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"route.prefer", "route.failover", "route.pacing", "permissions.default", "trust.repos", "bench.autosync"} {
		if _, ok := v.Edit[k]; !ok {
			t.Errorf("%s can't be changed from the tab", k)
		}
	}
	if _, ok := v.Edit["gateway"]; ok {
		t.Error("the gateway row has no form yet and must not claim one")
	}
	row := func(key string) string {
		t.Helper()
		v, err := s.Config(ctx)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range v.Rows {
			if r[0] == key {
				return r[1]
			}
		}
		return ""
	}
	for _, c := range []struct{ key, value, want string }{
		{"route.prefer", "cheap", "cheap"},
		{"route.pacing", "on", "on"},
		{"route.pacing", "off", "off"},
		{"permissions.default", "edits", "edits"},
		{"trust.repos", "~/src/app, ~/src/api", "2 trusted"},
	} {
		msg, err := s.ConfigSet(ctx, c.key, c.value)
		if err != nil || !strings.Contains(msg, "saved") {
			t.Fatalf("%s = %s: %q %v", c.key, c.value, msg, err)
		}
		if got := row(c.key); got != c.want {
			t.Errorf("%s shows %q after saving %q, want %q", c.key, got, c.value, c.want)
		}
	}
	path := config.PathsFor(c.Home, c.Getenv).Config
	before, _ := os.ReadFile(path)
	if _, err := s.ConfigSet(ctx, "trust.repos", "relative/path"); err == nil {
		t.Error("a relative trusted folder was saved")
	}
	if _, err := s.ConfigSet(ctx, "no.such.key", "x"); err == nil {
		t.Error("an unknown key was saved")
	}
	if after, _ := os.ReadFile(path); string(after) != string(before) {
		t.Error("a refused value changed the file")
	}
}

// The vendor usage lookup is one switch per CLI, off until it is turned
// on, and the warning is asked before it is.
func TestVendorUsageSwitchInTheConfigTab(t *testing.T) {
	c := panelCore(t)
	s := newPanelSource(c, "")
	ctx := context.Background()
	rows := func() map[string]string {
		t.Helper()
		v, err := s.Config(ctx)
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]string{}
		for _, r := range v.Rows {
			m[r[0]] = r[1]
		}
		for _, k := range []string{"harness.claude.vendor_usage", "harness.grok.vendor_usage"} {
			e, ok := v.Edit[k]
			if !ok || len(e.Choices) != 2 || !strings.Contains(e.Confirm, "terms") || !strings.Contains(e.Confirm, "login") {
				t.Errorf("%s: a switch that asks with the warning before it turns on: %+v", k, e)
			}
		}
		return m
	}
	if r := rows(); r["harness.claude.vendor_usage"] != "off" || r["harness.grok.vendor_usage"] != "off" {
		t.Fatalf("the lookup must start off: %v", r)
	}
	// Local engines are a switch as well.
	if v, _ := s.Config(ctx); len(v.Edit["local.engines"].Choices) != 2 {
		t.Errorf("local.engines has no switch: %+v", v.Edit["local.engines"])
	}
	if _, err := s.ConfigSet(ctx, "local.engines", "auto"); err != nil {
		t.Errorf("local.engines = auto: %v", err)
	}
	if _, ok := rows()["harness.agy.vendor_usage"]; ok {
		t.Error("agy has no vendor lookup and must not show a switch")
	}
	if _, err := s.ConfigSet(ctx, "harness.claude.vendor_usage", "on"); err != nil {
		t.Fatal(err)
	}
	if r := rows(); r["harness.claude.vendor_usage"] != "on" || r["harness.grok.vendor_usage"] != "off" {
		t.Errorf("after turning Claude's on: %v", r)
	}
	st, err := c.LoadSettings("")
	if err != nil || !st.VendorUsage["claude"] || st.VendorUsage["grok"] {
		t.Errorf("settings = %v %v", st.VendorUsage, err)
	}
	for _, bad := range [][2]string{{"harness.claude.vendor_usage", "yes please"}, {"harness.agy.vendor_usage", "on"}} {
		if _, err := s.ConfigSet(ctx, bad[0], bad[1]); err == nil {
			t.Errorf("%s = %s was saved", bad[0], bad[1])
		}
	}
	if _, err := s.ConfigSet(ctx, "harness.claude.vendor_usage", "off"); err != nil {
		t.Fatal(err)
	}
	if r := rows(); r["harness.claude.vendor_usage"] != "off" {
		t.Errorf("after turning it off: %v", r)
	}
}

// A gateway is added, filled in and removed from the Config tab; the key
// row takes a reference and refuses a key itself.
func TestGatewayFromTheConfigTab(t *testing.T) {
	c := panelCore(t)
	s := newPanelSource(c, "")
	ctx := context.Background()
	rows := func() map[string]string {
		t.Helper()
		v, err := s.Config(ctx)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]string{}
		for _, r := range v.Rows {
			out[r[0]] = r[1]
		}
		return out
	}
	if _, ok := rows()[gatewayNew]; !ok {
		t.Fatal("no row to add a gateway")
	}
	for _, bad := range []string{"", "work", "Work https://gw.example", "work gw.example:4000", "work https://user:pw@gw.example"} {
		if _, err := s.ConfigSet(ctx, gatewayNew, bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
	msg, err := s.ConfigSet(ctx, gatewayNew, "work https://gw.example:4000")
	if err != nil || !strings.Contains(msg, "gateway.work.key") || !strings.Contains(msg, "env:WORK_KEY") {
		t.Fatalf("%q %v", msg, err)
	}
	if _, err := s.ConfigSet(ctx, gatewayNew, "work https://other.example"); err == nil {
		t.Error("a second gateway with the same name was accepted")
	}
	r := rows()
	if r["gateway.work.url"] != "gw.example:4000" || r["gateway.work.key"] != "not set" || r["gateway"] != "work · gw.example:4000" {
		t.Errorf("rows after adding: %v", r)
	}
	path := config.PathsFor(c.Home, c.Getenv).Config
	before, _ := os.ReadFile(path)
	if _, err := s.ConfigSet(ctx, "gateway.work.key", "sk-live-123456"); err == nil {
		t.Error("a key itself was saved")
	}
	if after, _ := os.ReadFile(path); string(after) != string(before) {
		t.Error("the refused key reached the file")
	}
	for k, val := range map[string]string{"gateway.work.key": "env:WORK_KEY", "gateway.work.engine": "vllm", "gateway.work.default": "on"} {
		if _, err := s.ConfigSet(ctx, k, val); err != nil {
			t.Fatalf("%s: %v", k, err)
		}
	}
	if r := rows(); r["gateway.work.key"] != "env:WORK_KEY" || r["gateway.work.engine"] != "vllm" || r["gateway.work.default"] != "on" {
		t.Errorf("rows after editing: %v", r)
	}
	v, _ := s.Config(ctx)
	if v.Edit["gateway.work.url"].Remove != "gateway.work" {
		t.Error("a gateway row doesn't say what x removes")
	}
	if _, err := s.ConfigRemove(ctx, "route"); err == nil {
		t.Error("a section that isn't a gateway was removed")
	}
	if msg, err := s.ConfigRemove(ctx, "gateway.work"); err != nil || !strings.Contains(msg, "removed") {
		t.Fatalf("%q %v", msg, err)
	}
	if r := rows(); r["gateway.work.url"] != "" || r["gateway"] != "none" {
		t.Errorf("rows after removing: %v", r)
	}
}

func TestPaceText(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	out := "2026-11-30T14:00:00Z"
	for _, c := range []struct {
		pc    *router.Pacing
		want  string
		leans bool
	}{
		{nil, "", false},
		{&router.Pacing{UnusedAtResetPct: f(40), Adjustment: 1.2}, "~40% may go unused, so AFK leans to it", true},
		{&router.Pacing{UnusedAtResetPct: f(40)}, "~40% may go unused", false},
		{&router.Pacing{UnusedAtResetPct: f(2)}, "on track", false},
		{&router.Pacing{RunsOutAt: &out}, "may run out ", false},
	} {
		got, leans := paceText(c.pc)
		if !strings.HasPrefix(got, c.want) || (c.want == "" && got != "") || leans != c.leans {
			t.Errorf("paceText(%+v) = %q, %v; want %q, %v", c.pc, got, leans, c.want, c.leans)
		}
	}
}

func TestBenchSources(t *testing.T) {
	cat := &router.Catalog{SyncReceipt: map[string]any{"lmarena_agent": "live_synced", "lmarena_webdev": "offline", "synced_at": "2026-11-28T10:00:00Z"}}
	st := core.Settings{Learn: true, BenchSources: map[string]bool{"modelsdev": false}}
	src := benchSources(cat, st)
	by := map[string]tui.BenchSource{}
	for _, s := range src {
		by[s.Name] = s
	}
	if s := by["LMArena"]; !s.On || !strings.Contains(s.Status, "agent read, webdev offline, text never synced") {
		t.Errorf("lmarena %+v", s)
	}
	if by["models.dev"].On || !by["Your ratings"].On {
		t.Errorf("sources %+v", src)
	}
	if s := by["SWE-bench Verified"]; !s.On || s.Key != "bench.sources.swebench.enabled" || s.Weight != "1" || s.UsedFor != "complex, standard, review" {
		t.Errorf("swebench %+v", s)
	}
	if s := by["Artificial Analysis"]; s.On || s.Status != "off" {
		t.Errorf("artificial analysis is off until you turn it on: %+v", s)
	}
	// A weight set for one task shows per task.
	st.BenchWeights = map[string]map[string]float64{"coding_review": {"swebench": 2}}
	st.BenchCustom = map[string]config.BenchCustom{"my-evals": {URL: "https://example.com/b.json", Tasks: []string{"research"}}}
	by = map[string]tui.BenchSource{}
	for _, s := range benchSources(cat, st) {
		by[s.Name] = s
	}
	if s := by["SWE-bench Verified"]; s.Weight != "complex 1, standard 1, review 2" {
		t.Errorf("per-task weight %q", s.Weight)
	}
	if s := by["my-evals"]; !s.Own || s.Where != "https://example.com/b.json" || s.Key != "bench.custom.my-evals.enabled" || !s.On {
		t.Errorf("own source %+v", s)
	}
}
