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

func TestPatchIsAnEdit(t *testing.T) {
	if got := GuessTask("please investigate and patch the timeout"); got != "coding" {
		t.Errorf("investigate and patch = %s", got)
	}
	if got := GuessTask("please investigate the timeout"); got != "research" {
		t.Errorf("investigate = %s", got)
	}
}

func rollout(now int64, used float64, ts string) string {
	stamp := ""
	if ts != "" {
		stamp = fmt.Sprintf(`"timestamp":%q,`, ts)
	}
	return fmt.Sprintf(`{%s"payload":{"rate_limits":{"primary":{"used_percent":%v,"window_minutes":300,"resets_at":%d}}}}`, stamp, used, now+3000)
}

func TestCodexSessionsFollowCodexHome(t *testing.T) {
	home := t.TempDir()
	ch := filepath.Join(home, "elsewhere")
	for i := 0; i < 36; i++ {
		put(t, ch, fmt.Sprintf("sessions/s%d.jsonl", i), "{}", 0)
	}
	put(t, ch, "auth.json", `{"tokens":{"access_token":"x"}}`, 0)
	env := map[string]string{"CODEX_HOME": ch}
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
		Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(h string) bool { return h == "codex" },
		CodexLoginMode: func(context.Context) string { return "chatgpt" },
	})
	if got := *p.Pools["openai-plus"].UsedPct; got != 90 {
		t.Fatalf("openai-plus used %v, want 90 (36 of 40 sessions under CODEX_HOME)", got)
	}
}

func TestMeteredCodexIsNotChargedToThePlan(t *testing.T) {
	home := t.TempDir()
	for i := 0; i < 40; i++ {
		put(t, home, fmt.Sprintf(".codex/sessions/s%d.jsonl", i), "{}", 0)
	}
	put(t, home, ".codex/auth.json", `{"OPENAI_API_KEY":"sk-x"}`, 0)
	// How Codex is signed in comes from `codex login status`, never from
	// auth.json.
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "codex" },
		CodexLoginMode: func(context.Context) string { return "apikey" }})
	if got := *p.Pools["openai-plus"].UsedPct; got != 0 {
		t.Fatalf("API-key Codex sessions charged to the plan: %v%%", got)
	}
}

func TestBrokenSignalsAreIgnoredWhole(t *testing.T) {
	home := t.TempDir()
	put(t, home, ".config/afk/pool-signals.json", fmt.Sprintf(`{"pools":"bad","unavailable_models":{"m":{"updated_epoch":%d,"ttl_sec":3600}}}`, time.Now().Unix()), 0)
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(string) bool { return false }})
	if len(p.UnavailableModels) != 0 {
		t.Fatalf("a malformed signals file quarantined %v", p.UnavailableModels)
	}
}

func TestZeroCapacityIsSkipped(t *testing.T) {
	home := t.TempDir()
	put(t, home, ".config/afk/pool-signals.json", `{"pools":{"xai-grok":{"capacity_5h":0}}}`, 0)
	put(t, home, ".grok/auth.json", `{"a":1}`, 0)
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "grok" }})
	g := p.Pools["xai-grok"]
	if *g.Capacity5h != 50 || g.UsedPct == nil || *g.UsedPct != *g.UsedPct {
		t.Fatalf("xai-grok %+v", g)
	}
}

func TestCodexReadingIsTheNewestObserved(t *testing.T) {
	home := t.TempDir()
	now := time.Now().Unix()
	dir := ".codex/sessions/2026/11/26/"
	// The older session wrote the newer reading.
	put(t, home, dir+"rollout-2026-11-26T01.jsonl", rollout(now, 70, time.Unix(now-10, 0).UTC().Format(time.RFC3339)), 0)
	put(t, home, dir+"rollout-2026-11-26T02.jsonl", rollout(now, 20, time.Unix(now-600, 0).UTC().Format(time.RFC3339)), 0)
	q := probeCodexQuota(ProbeEnv{Home: home, Now: time.Now()})
	if !q.OK || q.UsedPct != 70 {
		t.Fatalf("got %+v, want the 70%% reading observed last", q)
	}
}

func TestCodexLastUsableRecordAndLongLines(t *testing.T) {
	home := t.TempDir()
	now := time.Now().Unix()
	long := `{"type":"x","blob":"` + strings.Repeat("a", maxRecord+10) + `"}`
	body := rollout(now, 30, "") + "\n" + long + "\n" + rollout(now, 95, "") + "\n" + `{"payload":{"rate_limits":null}}` + "\n"
	put(t, home, ".codex/sessions/rollout-2026-11-26T01.jsonl", body, 0)
	q := probeCodexQuota(ProbeEnv{Home: home, Now: time.Now()})
	if !q.OK || q.UsedPct != 95 {
		t.Fatalf("got %+v, want the last usable reading (95%%) past the long line and the null one", q)
	}
}

func TestGatewayErrorIsOffline(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
		fmt.Fprint(w, `{"data":[{"id":"m"}]}`)
	}))
	defer srv.Close()
	if gw := probeGateway(context.Background(), ProbeEnv{GatewayURL: srv.URL, Live: true, HTTP: srv.Client()}); gw.Online {
		t.Fatal("a 503 gateway is online")
	}
}

func TestEntitlementBelongsToTheCLIThatListsIt(t *testing.T) {
	probe := &Probe{Harnesses: map[string]HarnessState{"claude": {Installed: true}, "agy": {Installed: true}}, Pools: map[string]Pool{}}
	r := &Router{Catalog: DefaultCatalog(), Probe: probe, Discovered: []DiscoveredModel{{
		ID: "agy:claude-mythos", Harness: "agy", Model: "claude-mythos-5-2", CostClass: "subscription",
		EntitlementPool: "antigravity-pool", LaunchClass: "agy-native",
	}}}
	got := r.Select(Input{Stage: "review-security", Risk: "low", OnlyHarnesses: []string{"claude"}})
	if got.CandidateID == "claude-mythos-native" {
		t.Fatal("agy listing Mythos unlocked it on the Claude account")
	}
}

func TestServedByIncludesDiscoveredModels(t *testing.T) {
	r := &Router{Catalog: DefaultCatalog(), Discovered: []DiscoveredModel{{
		ID: "opencode:opencode/big-pickle", Harness: "opencode", Model: "opencode/big-pickle", CostClass: "free", IsFree: true,
		Capabilities: struct {
			Reasoning bool `json:"reasoning"`
			Toolcall  bool `json:"toolcall"`
		}{Toolcall: true},
	}}}
	got := r.ServedBy("opencode/big-pickle", []string{"opencode", "claude"}, false)
	if got["opencode"] != "opencode/big-pickle" || len(got) != 1 {
		t.Fatalf("ServedBy = %v", got)
	}
}

func TestServedByOffersEveryCLIThatServesIt(t *testing.T) {
	tc := struct {
		Reasoning bool `json:"reasoning"`
		Toolcall  bool `json:"toolcall"`
	}{Toolcall: true}
	r := &Router{Catalog: DefaultCatalog(), Discovered: []DiscoveredModel{{
		ID: "opencode:anthropic/claude-sonnet-5-5", Harness: "opencode", Model: "anthropic/claude-sonnet-5-5",
		CanonicalModel: "anthropic/claude-sonnet-5-5", CostClass: "subscription", EntitlementPool: "anthropic-max",
		Capabilities: tc,
	}}}
	// Which CLI runs a model is the user's choice: both are offered, so
	// --model alone asks which one.
	got := r.ServedBy("anthropic/claude-sonnet-5-5", []string{"opencode", "claude"}, false)
	if got["claude"] != "sonnet" || got["opencode"] != "anthropic/claude-sonnet-5-5" {
		t.Fatalf("ServedBy = %v", got)
	}
	// A gateway model runs on claude only (a technical limit).
	if got := r.ServedBy("qwen36-27b", []string{"claude"}, false); got["claude"] != "qwen36-27b" {
		t.Fatalf("gateway model: %v", got)
	}
}

func TestUnreadableSignalTimeUsesTheFileTime(t *testing.T) {
	home := t.TempDir()
	put(t, home, ".grok/auth.json", `{"a":1}`, 2*time.Hour)
	put(t, home, ".config/afk/pool-signals.json", `{"pools":{"xai-grok":{"degraded_reason":"401 unauthorized","updated_at":"not a time"}}}`, time.Hour)
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "grok" }})
	if p.Pools["xai-grok"].State != "auth_required" {
		t.Fatalf("a recent sign-in signal with a bad timestamp was dropped: %+v", p.Pools["xai-grok"])
	}
	// Renewing the login clears it.
	put(t, home, ".grok/auth.json", `{"a":2}`, 0)
	p = ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "grok" }})
	if p.Pools["xai-grok"].State == "auth_required" {
		t.Fatal("a renewed login did not clear the signal")
	}
	// A transient signal still expires.
	put(t, home, ".config/afk/pool-signals.json", `{"pools":{"xai-grok":{"degraded_reason":"timeout","updated_at":"bad","used_pct":100}}}`, time.Hour)
	p = ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "grok" }})
	if p.Pools["xai-grok"].QuotaSource == "runtime_signal:transient" {
		t.Fatal("an hour-old transient signal with a bad timestamp never expires")
	}
}

func TestSymlinkedCodexSessions(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks")
	}
	home := t.TempDir()
	real := filepath.Join(home, "real-sessions")
	put(t, real, "rollout-2026-11-26T01.jsonl", rollout(time.Now().Unix(), 44, ""), 0)
	for i := 0; i < 4; i++ {
		put(t, real, fmt.Sprintf("s%d.jsonl", i), "{}", 0)
	}
	if err := os.MkdirAll(filepath.Join(home, ".codex"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(home, ".codex", "sessions")); err != nil {
		t.Fatal(err)
	}
	e := ProbeEnv{Home: home, Now: time.Now()}
	if q := probeCodexQuota(e); !q.OK || q.UsedPct != 44 {
		t.Fatalf("symlinked sessions: %+v", q)
	}
	if n := countRecent(codexSessionsDir(e), time.Now().Add(-time.Hour)); n != 5 {
		t.Fatalf("countRecent through the symlink = %d, want 5", n)
	}
}

func TestPiCanWinARoute(t *testing.T) {
	probe := &Probe{Harnesses: map[string]HarnessState{"pi": {Installed: true}}, Pools: map[string]Pool{}}
	r := &Router{Catalog: DefaultCatalog(), Probe: probe, Discovered: []DiscoveredModel{{
		ID: "pi:free", Harness: "pi", Model: "free-model", CostClass: "free", IsFree: true,
		EntitlementPool: "opencode-free", LaunchClass: "pi-native",
		Capabilities: struct {
			Reasoning bool `json:"reasoning"`
			Toolcall  bool `json:"toolcall"`
		}{Toolcall: true},
	}}}
	if got := r.Select(Input{Stage: "build", Risk: "low", PreferFree: true}); got.Harness != "pi" {
		t.Fatalf("pi was not routed to: %+v", got)
	}
}

func TestAnotherVendorsPlanNeedsThatCLIsLogin(t *testing.T) {
	probe := &Probe{
		Harnesses: map[string]HarnessState{"opencode": {Installed: true}},
		Pools:     map[string]Pool{"xai-grok": {State: "available"}},
		Bindings:  map[string][]string{"xai-grok": {"grok"}},
	}
	r := &Router{Catalog: DefaultCatalog(), Probe: probe}
	if got := r.Select(Input{Stage: "build", Risk: "low", OnlyHarnesses: []string{"opencode"}}); got.Model == "xai/grok-4.5" {
		t.Fatal("opencode was offered xAI's plan without being signed in to it")
	}
	probe.Bindings["xai-grok"] = []string{"grok", "opencode"}
	if got := r.Select(Input{Stage: "build", Risk: "low", OnlyHarnesses: []string{"opencode"}}); got.Model != "xai/grok-4.5" {
		t.Fatalf("opencode signed in to xAI was not offered it: %+v", got)
	}
}

// With CODEX_HOME set, the login file is $CODEX_HOME/auth.json: an
// API-key login there keeps its sessions out of the ChatGPT plan pool.
func TestMeteredCodexUnderCodexHome(t *testing.T) {
	home := t.TempDir()
	ch := filepath.Join(home, "elsewhere")
	for i := 0; i < 40; i++ {
		put(t, ch, fmt.Sprintf("sessions/s%d.jsonl", i), "{}", 0)
	}
	put(t, ch, "auth.json", `{"OPENAI_API_KEY":"sk-x"}`, 0)
	env := map[string]string{"CODEX_HOME": ch}
	probe := func(mode string) *Probe {
		asked := false
		p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
			Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(h string) bool { return h == "codex" },
			CodexLoginMode: func(context.Context) string { asked = true; return mode },
		})
		if !asked {
			t.Fatalf("codex login status was not asked with CODEX_HOME=%s", ch)
		}
		return p
	}
	if got := *probe("apikey").Pools["openai-plus"].UsedPct; got != 0 {
		t.Fatalf("API-key sessions under CODEX_HOME charged to the plan: %v%%", got)
	}
	// Each probe asks again, so a new login is seen at once.
	if got := *probe("chatgpt").Pools["openai-plus"].UsedPct; got != 98 {
		t.Fatalf("a ChatGPT login under CODEX_HOME: %v%%, want 98 (40 sessions, capped)", got)
	}
}

// When Codex can't say how it is signed in, its sessions are counted
// against no pool and it is bound to neither the plan nor metered use.
func TestUnknownCodexLoginIsNotTakenForThePlan(t *testing.T) {
	home := t.TempDir()
	for i := 0; i < 40; i++ {
		put(t, home, fmt.Sprintf(".codex/sessions/s%d.jsonl", i), "{}", 0)
	}
	put(t, home, ".codex/auth.json", `{"tokens":{"access_token":"x"}}`, 0)
	for _, mode := range []func(context.Context) string{nil, func(context.Context) string { return "" }} {
		p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "codex" }, CodexLoginMode: mode})
		if got := *p.Pools["openai-plus"].UsedPct; got != 0 {
			t.Fatalf("sessions of an unknown Codex login charged to the plan: %v%%", got)
		}
		if contains(p.Bindings["openai-plus"], "codex") || contains(p.Bindings["api-metered"], "codex") {
			t.Fatalf("an unknown Codex login was bound: %v", p.Bindings)
		}
	}
}

// Only a newer Codex login clears a sign-in signal on openai-plus; a newer
// OpenCode login file doesn't.
func TestOnlyACodexLoginClearsTheCodexAuthSignal(t *testing.T) {
	home := t.TempDir()
	put(t, home, ".codex/auth.json", `{"tokens":{"access_token":"x"}}`, time.Hour)
	put(t, home, ".config/afk/pool-signals.json", fmt.Sprintf(`{"pools":{"openai-plus":{"degraded_reason":"401 unauthorized","updated_epoch":%d}}}`, time.Now().Unix()-60), 0)
	put(t, home, ".local/share/opencode/auth.json", `{"openai":{"type":"oauth"}}`, 0)
	probe := func() Pool {
		return ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "codex" || h == "opencode" },
			CodexLoginMode: func(context.Context) string { return "chatgpt" }}).Pools["openai-plus"]
	}
	if s := probe(); s.State != "auth_required" {
		t.Fatalf("a newer OpenCode login cleared Codex's sign-in signal: %+v", s)
	}
	put(t, home, ".codex/auth.json", `{"tokens":{"access_token":"new"}}`, 0)
	if s := probe(); s.State == "auth_required" {
		t.Fatalf("a new Codex login did not clear the signal: %+v", s)
	}
}

// CLAUDE_CONFIG_DIR is where Claude Code keeps its sessions and login.
func TestClaudeConfigDir(t *testing.T) {
	home := t.TempDir()
	cd := filepath.Join(home, "claude-elsewhere")
	for i := 0; i < 30; i++ {
		put(t, cd, fmt.Sprintf("projects/a/s%d.jsonl", i), "{}", 0)
	}
	put(t, cd, ".credentials.json", `{"claudeAiOauth":{"accessToken":"x"}}`, 2*time.Hour)
	put(t, home, ".config/afk/pool-signals.json", fmt.Sprintf(`{"pools":{"anthropic-max":{"degraded_reason":"401 unauthorized","updated_epoch":%d}}}`, time.Now().Unix()-3600), 0)
	env := map[string]string{"CLAUDE_CONFIG_DIR": cd}
	probe := func() *Probe {
		return ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(h string) bool { return h == "claude" }})
	}
	p := probe()
	if !contains(p.Bindings["anthropic-max"], "claude") {
		t.Fatalf("claude not bound with its login under CLAUDE_CONFIG_DIR: %v", p.Bindings)
	}
	if s := p.Pools["anthropic-max"]; s.State != "auth_required" {
		t.Fatalf("signal: %+v", s)
	}
	// A new login in CLAUDE_CONFIG_DIR clears the sign-in signal, and the
	// sessions there are counted: 30 of 60.
	put(t, cd, ".credentials.json", `{"claudeAiOauth":{"accessToken":"y"}}`, 0)
	s := probe().Pools["anthropic-max"]
	if s.State == "auth_required" || *s.UsedPct != 50 {
		t.Fatalf("after a new login under CLAUDE_CONFIG_DIR: %+v", s)
	}
}

func TestOnlyPoolLimitsTheChoiceToThatPool(t *testing.T) {
	probe := &Probe{Harnesses: map[string]HarnessState{"claude": {Installed: true}, "codex": {Installed: true}}, Pools: map[string]Pool{}}
	r := &Router{Catalog: DefaultCatalog(), Probe: probe}
	any := r.Select(Input{Stage: "build", Risk: "low"})
	if any.IsFallback() || any.EntitlementPool == "" {
		t.Fatalf("no pooled route to start from: %+v", any)
	}
	for _, pool := range []string{"anthropic-max", "openai-plus"} {
		got := r.Select(Input{Stage: "build", Risk: "low", OnlyPool: pool})
		if got.IsFallback() || got.EntitlementPool != pool {
			t.Errorf("OnlyPool %s chose %s on pool %q", pool, got.CandidateID, got.EntitlementPool)
		}
	}
}
