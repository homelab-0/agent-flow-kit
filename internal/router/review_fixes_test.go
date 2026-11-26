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
	"syscall"
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
	put(t, home, ".codex/auth.json", `{"tokens":{"access_token":"x"}}`, 0)
	env := map[string]string{"CODEX_HOME": ch}
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{
		Home: home, Getenv: func(k string) string { return env[k] }, Installed: func(h string) bool { return h == "codex" },
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
	p := ProbePools(context.Background(), DefaultCatalog(), ProbeEnv{Home: home, Installed: func(h string) bool { return h == "codex" }})
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

func TestClaudeUsageWithNoFiguresIsNotAReading(t *testing.T) {
	if q := parseClaudeUsage([]byte(`{"five_hour":null,"seven_day":null}`)); q.OK {
		t.Fatalf("nulls read as %v%% used", q.UsedPct)
	}
	if q := parseClaudeUsage([]byte(`{"five_hour":{"utilization":0},"seven_day":null}`)); !q.OK || q.UsedPct != 0 {
		t.Fatalf("an explicit 0 is a reading: %+v", q)
	}
}

func TestClaudeCacheBelongsToTheLogin(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		fmt.Fprintf(w, `{"five_hour":{"utilization":%d}}`, calls*10)
	}))
	defer srv.Close()
	home := t.TempDir()
	put(t, home, ".claude/.credentials.json", `{"claudeAiOauth":{"accessToken":"a"}}`, time.Minute)
	e := ProbeEnv{Home: home, Live: true, ClaudeUsageURL: srv.URL, HTTP: srv.Client(), Now: time.Now()}
	if q := probeClaudeQuota(context.Background(), e); q.UsedPct != 10 {
		t.Fatalf("first %v", q.UsedPct)
	}
	put(t, home, ".claude/.credentials.json", `{"claudeAiOauth":{"accessToken":"someone-else"}}`, 0)
	if q := probeClaudeQuota(context.Background(), e); q.UsedPct != 20 || calls != 2 {
		t.Fatalf("after a new login: %v%% from %d calls; the old login's cache was reused", q.UsedPct, calls)
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

func TestCodexSkipsNamedPipes(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no fifos")
	}
	home := t.TempDir()
	dir := filepath.Join(home, ".codex/sessions")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(dir, "rollout-2026-11-26T09.jsonl"), 0o600); err != nil {
		t.Skip("mkfifo:", err)
	}
	done := make(chan quota, 1)
	go func() { done <- probeCodexQuota(ProbeEnv{Home: home, Now: time.Now()}) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("the probe blocked on a named pipe")
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

func TestServedByAppliesTheLoginRules(t *testing.T) {
	tc := struct {
		Reasoning bool `json:"reasoning"`
		Toolcall  bool `json:"toolcall"`
	}{Toolcall: true}
	r := &Router{Catalog: DefaultCatalog(), Discovered: []DiscoveredModel{{
		ID: "opencode:anthropic/claude-sonnet-5-5", Harness: "opencode", Model: "anthropic/claude-sonnet-5-5",
		CanonicalModel: "anthropic/claude-sonnet-5-5", CostClass: "subscription", EntitlementPool: "anthropic-max",
		Capabilities: tc,
	}}}
	got := r.ServedBy("anthropic/claude-sonnet-5-5", []string{"opencode", "claude"}, false)
	if _, ok := got["opencode"]; ok {
		t.Fatalf("a Claude plan model was offered on opencode: %v", got)
	}
	if got["claude"] != "sonnet" {
		t.Fatalf("claude should serve it as sonnet: %v", got)
	}
	// The gateway model in the catalog stays pinnable on claude.
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

func TestPiNeverWinsARoute(t *testing.T) {
	probe := &Probe{Harnesses: map[string]HarnessState{"pi": {Installed: true}}, Pools: map[string]Pool{}}
	r := &Router{Catalog: DefaultCatalog(), Probe: probe, Discovered: []DiscoveredModel{{
		ID: "pi:free", Harness: "pi", Model: "free-model", CostClass: "free", IsFree: true,
		EntitlementPool: "opencode-free", LaunchClass: "pi-native",
		Capabilities: struct {
			Reasoning bool `json:"reasoning"`
			Toolcall  bool `json:"toolcall"`
		}{Toolcall: true},
	}}}
	if got := r.Select(Input{Stage: "build", Risk: "low", PreferFree: true}); got.Harness == "pi" {
		t.Fatalf("pi won: %+v", got)
	}
}
