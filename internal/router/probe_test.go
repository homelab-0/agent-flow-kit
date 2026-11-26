package router

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func put(t *testing.T, home, rel, body string, age time.Duration) {
	t.Helper()
	p := filepath.Join(home, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if age > 0 {
		old := time.Now().Add(-age)
		if err := os.Chtimes(p, old, old); err != nil {
			t.Fatal(err)
		}
	}
}

// fakeHome is the machine the bash probe was compared against: the
// expected figures below are what afk_router_probe_pools reported for it.
func fakeHome(t *testing.T) (string, map[string]string) {
	home := t.TempDir()
	now := time.Now().Unix()
	put(t, home, ".claude/.credentials.json", `{"claudeAiOauth":{"accessToken":"fake"}}`, 0)
	for i := 0; i < 7; i++ {
		put(t, home, fmt.Sprintf(".claude/projects/a/b/s%d.jsonl", i), "{}", 0)
	}
	put(t, home, ".claude/projects/a/b/old.jsonl", "{}", 10*time.Hour)
	put(t, home, ".claude/projects/a/b/c/d/e/f/deep.jsonl", "{}", 0) // too deep to count
	put(t, home, ".codex/auth.json", `{"tokens":{"access_token":"x","account_id":"acct1"}}`, 0)
	put(t, home, ".codex/sessions/2026/11/26/rollout-2026-11-26T01.jsonl", fmt.Sprintf(
		"{\"type\":\"x\"}\n{\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":42.4,\"window_minutes\":300,\"resets_at\":%d},\"secondary\":{\"used_percent\":61.6,\"window_minutes\":10080,\"resets_at\":%d},\"plan_type\":\"pro\"}}}\n{\"type\":\"y\"}\n",
		now+3000, now+90000), 0)
	// Newer by name, but its only window has already reset.
	put(t, home, ".codex/sessions/2026/11/26/rollout-2026-11-26T02.jsonl", fmt.Sprintf(
		"{\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":99,\"window_minutes\":300,\"resets_at\":%d}}}}\n", now-50), 0)
	put(t, home, ".grok/auth.json", `{"x::uid42":{"t":1}}`, 0)
	for i := 0; i < 3; i++ {
		put(t, home, fmt.Sprintf(".local/share/opencode/x/m%d.json", i), "{}", 0)
	}
	put(t, home, ".local/share/opencode/auth.json", `{"xai":{"type":"oauth"},"anthropic":{"type":"api"}}`, 0)
	put(t, home, ".pi/agent/auth.json", `{"openai-codex":{"type":"oauth"}}`, 0)
	put(t, home, ".pi/agent/sessions/a.jsonl", "{}", 0)
	put(t, home, ".pi/agent/sessions/b.jsonl", "{}", 0)
	for _, d := range []string{"one", "two"} {
		if err := os.MkdirAll(filepath.Join(home, ".gemini/antigravity-cli/brain", d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	old := filepath.Join(home, ".gemini/antigravity-cli/brain/old")
	_ = os.MkdirAll(old, 0o755)
	ot := time.Now().Add(-10 * time.Hour)
	_ = os.Chtimes(old, ot, ot)
	put(t, home, "claude-usage.json", `{"five_hour":{"utilization":33.4},"seven_day":{"utilization":50,"resets_at":"2026-11-30T00:00:00Z"},"limits":[{"is_active":true,"group":"scoped_weekly","kind":"weekly_scoped","name":"Fable","percent":70.2}],"extra_usage":{"is_enabled":false}}`, 0)
	put(t, home, ".config/afk/pool-signals.json", fmt.Sprintf(
		`{"pools":{"antigravity-pool":{"degraded_reason":"429 quota","updated_epoch":%d,"used_pct":100},"openai-plus":{"degraded_reason":"401 unauthorized","updated_epoch":%d,"used_pct":100}},"unavailable_models":{"m-fresh":{"reason":"403","updated_epoch":%d,"ttl_sec":3600},"m-old":{"reason":"403","updated_epoch":%d,"ttl_sec":3600}}}`,
		now-100, now-999999, now-60, now-7200), 0)
	return home, map[string]string{"AFK_CLAUDE_USAGE_FIXTURE": filepath.Join(home, "claude-usage.json")}
}

func TestProbePoolsMatchesBashProbe(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("file times")
	}
	home, env := fakeHome(t)
	installed := map[string]bool{"claude": true, "codex": true, "opencode": true, "grok": true, "pi": true}
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
		Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(h string) bool { return installed[h] },
	})
	type want struct {
		state, src        string
		used, cap, remain float64
		week, five, fable float64 // -1: none
	}
	wants := map[string]want{
		"anthropic-max":    {"available", "anthropic_oauth_api", 50, 60, 30, 50, 33, 70},
		"openai-plus":      {"available", "codex_rate_limits", 62, 40, 15, 62, 42, -1},
		"antigravity-pool": {"exhausted", "runtime_signal:quota", 100, 50, 0, -1, -1, -1},
		"xai-grok":         {"available", "local_5h_activity", 10, 50, 45, -1, -1, -1},
		"opencode-free":    {"available", "local_5h_activity", 2, 200, 196, -1, -1, -1},
		"litellm-local":    {"offline", "gateway_probe", 100, 9999, 0, -1, -1, -1},
	}
	opt := func(v *float64) float64 {
		if v == nil {
			return -1
		}
		return *v
	}
	for id, w := range wants {
		g := p.Pools[id]
		got := want{g.State, g.QuotaSource, *g.UsedPct, *g.Capacity5h, *g.Remaining5h, opt(g.WeeklyUsedPct), opt(g.FiveHourUsedPct), opt(g.FableWeeklyUsedPct)}
		if got != w {
			t.Errorf("%s:\n got  %+v\n want %+v", id, got, w)
		}
	}
	if len(p.AuthAlerts) != 0 {
		t.Errorf("alerts %v", p.AuthAlerts)
	}
	if _, ok := p.UnavailableModels["m-fresh"]; !ok || len(p.UnavailableModels) != 1 {
		t.Errorf("unavailable %v", p.UnavailableModels)
	}
}

func TestProbePoolsAuthAlerts(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("file times")
	}
	home, env := fakeHome(t)
	_ = os.Remove(filepath.Join(home, ".grok/auth.json"))
	put(t, home, ".local/share/opencode/auth.json", `{"xai":{"type":"api"}}`, 0)
	put(t, home, ".claude/.credentials.json", `{"claudeAiOauth":{"accessToken":"fake"}}`, time.Hour)
	put(t, home, ".config/afk/pool-signals.json", fmt.Sprintf(`{"pools":{"anthropic-max":{"degraded_reason":"401 token revoked","updated_epoch":%d}}}`, time.Now().Unix()-60), 0)
	put(t, home, "claude-usage.json", `{"five_hour":{"utilization":80},"seven_day":{"utilization":95},"extra_usage":{"is_enabled":true,"utilization":50}}`, 0)
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
		Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(h string) bool { return h == "claude" || h == "grok" },
	})
	if s := p.Pools["anthropic-max"]; s.State != "auth_required" || *s.UsedPct != 80 {
		t.Errorf("anthropic %+v", s)
	}
	if s := p.Pools["xai-grok"]; s.State != "offline" || s.QuotaSource != "unauthenticated" {
		t.Errorf("xai %+v", s)
	}
	if len(p.AuthAlerts) != 2 {
		t.Fatalf("alerts %v", p.AuthAlerts)
	}
	// A new login clears the sign-in signal.
	put(t, home, ".claude/.credentials.json", `{"claudeAiOauth":{"accessToken":"new"}}`, 0)
	p = ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
		Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(h string) bool { return h == "claude" },
	})
	if s := p.Pools["anthropic-max"]; s.State == "auth_required" {
		t.Errorf("a renewed login is still auth_required")
	}
}

func TestClaudeUsageLiveCallIsCachedAndNeverLogsTheToken(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer tok-123" || r.Header.Get("anthropic-beta") == "" {
			w.WriteHeader(401)
			return
		}
		fmt.Fprint(w, `{"five_hour":{"utilization":12},"seven_day":{"utilization":20}}`)
	}))
	defer srv.Close()
	home := t.TempDir()
	put(t, home, ".claude/.credentials.json", `{"claudeAiOauth":{"accessToken":"tok-123"}}`, 0)
	e := ProbeEnv{Home: home, Live: true, ClaudeUsageURL: srv.URL, HTTP: srv.Client(), Now: time.Now()}
	for i := 0; i < 2; i++ {
		q := probeClaudeQuota(context.Background(), e)
		if !q.OK || q.UsedPct != 20 {
			t.Fatalf("quota %+v", q)
		}
	}
	if calls != 1 {
		t.Fatalf("usage API called %d times; the second read should come from the cache", calls)
	}
	b, err := os.ReadFile(filepath.Join(home, ".config/afk/live-quota-cache.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(b) == "" || strings.Contains(string(b), "tok-123") {
		t.Fatalf("cache holds the token or nothing: %s", b)
	}
	if fi, _ := os.Stat(filepath.Join(home, ".config/afk/live-quota-cache.json")); runtime.GOOS != "windows" && fi.Mode().Perm() != 0o600 {
		t.Fatalf("cache mode %v", fi.Mode().Perm())
	}
}

func TestGatewayProbe(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" {
			w.WriteHeader(404)
			return
		}
		fmt.Fprint(w, `{"data":[{"id":"qwen36-27b"},{"id":"llama"}]}`)
	}))
	defer srv.Close()
	gw := probeGateway(context.Background(), ProbeEnv{GatewayURL: srv.URL + "/", Live: true, HTTP: srv.Client()})
	if !gw.Online || len(gw.Models) != 2 || gw.Models[0] != "qwen36-27b" {
		t.Fatalf("gateway %+v", gw)
	}
	if gw := probeGateway(context.Background(), ProbeEnv{GatewayURL: "http://127.0.0.1:1", Live: true, HTTP: srv.Client()}); gw.Online {
		t.Fatal("an unreachable gateway is online")
	}
}

func TestParseClaudeUsage(t *testing.T) {
	cases := []struct {
		body  string
		used  float64
		fable float64
	}{
		{`{"five_hour":{"utilization":10},"seven_day":{"utilization":40}}`, 40, -1},
		// Extra usage with room discounts the weekly figure.
		{`{"five_hour":{"utilization":10},"seven_day":{"utilization":90},"extra_usage":{"is_enabled":true,"utilization":10}}`, 72, -1},
		// Without a utilization figure it is taken as full.
		{`{"five_hour":{"utilization":10},"seven_day":{"utilization":90},"extra_usage":{"is_enabled":true}}`, 90, -1},
		// Weekly from limits when seven_day is missing; Fable kept apart.
		{`{"limits":[{"is_active":true,"group":"weekly","percent":55},{"is_active":true,"kind":"fable_weekly","percent":99}]}`, 55, 99},
		{`{"seven_day_fable":{"utilization":12.6},"five_hour":{"utilization":150}}`, 100, 13},
	}
	for _, c := range cases {
		q := parseClaudeUsage([]byte(c.body))
		f := -1.0
		if q.FableWeeklyPct != nil {
			f = *q.FableWeeklyPct
		}
		if !q.OK || q.UsedPct != c.used || f != c.fable {
			t.Errorf("%s: used %v fable %v, want %v %v", c.body, q.UsedPct, f, c.used, c.fable)
		}
	}
	if q := parseClaudeUsage([]byte(`{"error":"x"}`)); q.OK {
		t.Error("an error body is a reading")
	}
}
