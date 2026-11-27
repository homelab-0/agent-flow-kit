package router

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
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
// expected figures below are what afk_router_probe_pools reported for it,
// except where noted.
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
		put(t, home, fmt.Sprintf(".local/share/opencode/storage/message/m%d.json", i), "{}", 0)
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
	put(t, home, ".config/afk/pool-signals.json", fmt.Sprintf(
		`{"pools":{"antigravity-pool":{"degraded_reason":"429 quota","updated_epoch":%d,"used_pct":100},"openai-plus":{"degraded_reason":"401 unauthorized","updated_epoch":%d,"used_pct":100}},"unavailable_models":{"m-fresh":{"reason":"403","updated_epoch":%d,"ttl_sec":3600},"m-old":{"reason":"403","updated_epoch":%d,"ttl_sec":3600}}}`,
		now-100, now-999999, now-60, now-7200), 0)
	return home, map[string]string{}
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
		state, src              string
		used, week, five, fable float64 // -1: none
	}
	wants := map[string]want{
		// A pool has figures only when its CLI reported them: Codex's
		// rate limits here. Claude, Grok and OpenCode have recent session
		// files in this home, and still show no figure: AFK never
		// estimates usage from activity.
		"anthropic-max":    {"available", "unknown", -1, -1, -1, -1},
		"openai-plus":      {"available", "codex_rate_limits", 62, 62, 42, -1},
		"antigravity-pool": {"exhausted", "runtime_signal:quota", -1, -1, -1, -1},
		"xai-grok":         {"available", "unknown", -1, -1, -1, -1},
		"opencode-free":    {"available", "unknown", -1, -1, -1, -1},
		"litellm-local":    {"offline", "gateway_probe", -1, -1, -1, -1},
	}
	opt := func(v *float64) float64 {
		if v == nil {
			return -1
		}
		return *v
	}
	for id, w := range wants {
		g := p.Pools[id]
		got := want{g.State, g.QuotaSource, opt(g.UsedPct), opt(g.WeeklyUsedPct), opt(g.FiveHourUsedPct), opt(g.FableWeeklyUsedPct)}
		if got != w {
			t.Errorf("%s:\n got  %+v\n want %+v", id, got, w)
		}
		// A plan name is shown only when the CLI reported one (Codex
		// does, with its rate limits); it is never filled in from a guess.
		if wantPlan := map[string]string{"openai-plus": "pro"}[id]; g.Plan != wantPlan {
			t.Errorf("%s: plan %q, want %q", id, g.Plan, wantPlan)
		}
		if (g.UsedPct == nil) != (g.HeadroomPct == nil) {
			t.Errorf("%s: used %v but headroom %v", id, g.UsedPct, g.HeadroomPct)
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
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
		Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(h string) bool { return h == "claude" || h == "grok" },
	})
	if s := p.Pools["anthropic-max"]; s.State != "auth_required" {
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

// The probe and the sign-in checks only look at whether login files exist:
// with every credential file unreadable, nothing changes.
func TestCredentialFilesAreNeverOpened(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("file modes")
	}
	home, env := fakeHome(t)
	creds := []string{".claude/.credentials.json", ".codex/auth.json", ".grok/auth.json", ".local/share/opencode/auth.json", ".pi/agent/auth.json"}
	probe := func() *Probe {
		return ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
			Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(string) bool { return true },
			CodexLoginMode: func(context.Context) string { return "chatgpt" },
		})
	}
	before := probe()
	for _, c := range creds {
		if err := os.Chmod(filepath.Join(home, c), 0); err != nil {
			t.Fatal(err)
		}
	}
	after := probe()
	for _, c := range creds {
		if f, err := os.Open(filepath.Join(home, c)); err == nil {
			f.Close()
			t.Fatalf("%s is still readable; the test can't prove anything", c)
		}
	}
	for id, b := range before.Pools {
		a := after.Pools[id]
		same := (a.UsedPct == nil) == (b.UsedPct == nil) && (a.UsedPct == nil || *a.UsedPct == *b.UsedPct)
		if a.State != b.State || !same || a.QuotaSource != b.QuotaSource {
			t.Errorf("%s changed when the credential files became unreadable: %+v -> %+v", id, b, a)
		}
	}
	got := accountBindings(ProbeEnv{Home: home, Getenv: func(k string) string { return env[k] }}, map[string]HarnessState{}, "chatgpt", nil)
	for pool, h := range map[string]string{"anthropic-max": "claude", "openai-plus": "codex", "xai-grok": "grok", "opencode-free": "opencode"} {
		if !contains(got[pool], h) {
			t.Errorf("%s not bound to %s with an unreadable login file: %v", h, pool, got)
		}
	}
	if b := accountBindings(ProbeEnv{Home: home}, map[string]HarnessState{}, "apikey", nil); !contains(b["api-metered"], "codex") || contains(b["openai-plus"], "codex") {
		t.Errorf("an API-key Codex is metered: %v", b)
	}
}

// Session files are never turned into a usage figure: a plan whose CLI
// reported nothing shows none, however busy its folder is.
func TestActivityIsNeverAUsageFigure(t *testing.T) {
	home := t.TempDir()
	for i := 0; i < 30; i++ {
		put(t, home, fmt.Sprintf(".claude/projects/a/s%d.jsonl", i), "{}", 0)
		put(t, home, fmt.Sprintf(".grok/sessions/s%d.json", i), "{}", 0)
		put(t, home, fmt.Sprintf(".local/share/opencode/storage/session/s%d.json", i), "{}", 0)
	}
	put(t, home, ".grok/auth.json", `{"x":{"t":1}}`, 0)
	put(t, home, ".gemini/antigravity-cli/brain/one/x.json", "{}", 0)
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(string) bool { return true }})
	for _, id := range []string{"anthropic-max", "xai-grok", "antigravity-pool", "opencode-free", "openai-plus"} {
		g := p.Pools[id]
		if g.UsedPct != nil || g.HeadroomPct != nil || g.QuotaSource != SourceUnknown || g.State != "available" {
			t.Errorf("%s: %+v, want available with no figure (source unknown)", id, g)
		}
	}
}

// Antigravity installed but never signed in is not a signed-in plan with
// everything left: it is offline, with a sign-in alert and no figure.
func TestInstalledAgyIsNotSignedIn(t *testing.T) {
	home := t.TempDir()
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "agy" }})
	g := p.Pools["antigravity-pool"]
	if g.State != "offline" || g.QuotaSource != SourceSignedOut || g.HeadroomPct != nil || len(p.Bindings["antigravity-pool"]) != 0 {
		t.Fatalf("agy with no login: %+v, bound %v", g, p.Bindings["antigravity-pool"])
	}
	found := false
	for _, a := range p.AuthAlerts {
		if m, _ := a.(map[string]any); m["pool"] == "antigravity-pool" && m["reauth_command"] == "agy login" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no sign-in alert for agy: %v", p.AuthAlerts)
	}
	// Once it has signed in, it is a plan with unknown usage.
	put(t, home, ".gemini/antigravity-cli/state.json", "{}", 0)
	p = ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "agy" }})
	if g := p.Pools["antigravity-pool"]; g.State != "available" || g.QuotaSource != SourceUnknown || g.HeadroomPct != nil {
		t.Fatalf("signed-in agy: %+v", g)
	}
}

// A plan CLI whose own status command says it is signed out is not a
// signed-in plan, whatever login file is on disk: its pool is offline,
// with a sign-in alert. No answer leaves the file check to decide.
func TestStatusCommandSignsAPoolOut(t *testing.T) {
	home := t.TempDir()
	put(t, home, ".claude/.credentials.json", `{"claudeAiOauth":{"accessToken":"x"}}`, 0)
	put(t, home, ".codex/auth.json", `{"tokens":{"access_token":"x"}}`, 0)
	probe := func(answer map[string]bool) *Probe {
		return ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
			Home: home, Installed: func(h string) bool { return h == "claude" || h == "codex" },
			CodexLoginMode: func(context.Context) string { return "chatgpt" },
			SignedIn: func(_ context.Context, h string) (bool, bool) {
				in, known := answer[h]
				return in, known
			},
		})
	}
	p := probe(map[string]bool{"claude": false, "codex": true})
	if g := p.Pools["anthropic-max"]; g.State != "offline" || g.QuotaSource != SourceSignedOut || len(p.Bindings["anthropic-max"]) != 0 {
		t.Fatalf("claude signed out by its status command: %+v, bound %v", g, p.Bindings)
	}
	if g := p.Pools["openai-plus"]; g.State != "available" || !contains(p.Bindings["openai-plus"], "codex") {
		t.Fatalf("codex signed in: %+v, bound %v", g, p.Bindings)
	}
	alert := false
	for _, a := range p.AuthAlerts {
		if m, _ := a.(map[string]any); m["pool"] == "anthropic-max" && m["reauth_command"] == "claude auth login" {
			alert = true
		}
	}
	if !alert {
		t.Fatalf("no sign-in alert for claude: %v", p.AuthAlerts)
	}
	// No answer from either: the login files decide.
	p = probe(nil)
	if g := p.Pools["anthropic-max"]; g.State != "available" || !contains(p.Bindings["anthropic-max"], "claude") {
		t.Fatalf("claude with no status answer: %+v", g)
	}
}
