package harness

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseClaudeUsage(t *testing.T) {
	w, x := ParseClaudeUsage([]byte(`{"five_hour":{"utilization":12.4,"resets_at":"2026-11-28T15:00:00Z"},
		"seven_day":{"used_percentage":140,"resets_at":1795000000},
		"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250}}`))
	if len(w) != 2 || w[0].Minutes != 300 || w[0].UsedPct != 12.4 || w[0].ResetsAt != time.Date(2026, 11, 28, 15, 0, 0, 0, time.UTC).Unix() {
		t.Fatalf("windows = %+v", w)
	}
	if w[1].Minutes != 10080 || w[1].UsedPct != 100 || w[1].ResetsAt != 1795000000 {
		t.Errorf("weekly = %+v", w[1])
	}
	if x == nil || !x.Enabled || x.Limit != "50.00" || x.Spent != "12.50" || x.Currency != "USD" {
		t.Errorf("extra = %+v", x)
	}
	// Nothing usable is no windows, never a zero.
	if w, _ := ParseClaudeUsage([]byte(`{"five_hour":{}}`)); len(w) != 0 {
		t.Errorf("an empty window became %+v", w)
	}
	if w, x := ParseClaudeUsage([]byte(`not json`)); w != nil || x != nil {
		t.Error("bad JSON gave figures")
	}
}

func TestParseGrokBilling(t *testing.T) {
	plan, w, x := ParseGrokBilling([]byte(`{"config":{"creditUsagePercent":37,
		"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-23T00:00:00Z","end":"2026-11-30T00:00:00Z"},
		"subscriptionTier":"SuperGrok","onDemandCap":{"val":"50"},"onDemandUsed":{"val":"5.5"},"prepaidBalance":{"val":3}}}`))
	if plan != "SuperGrok" || len(w) != 1 || w[0].Minutes != 10080 || w[0].UsedPct != 37 || w[0].ResetsAt != time.Date(2026, 11, 30, 0, 0, 0, 0, time.UTC).Unix() {
		t.Fatalf("plan %q windows %+v", plan, w)
	}
	if x == nil || !x.Enabled || x.Limit != "50.00" || x.Spent != "5.50" || x.Balance != "3.00" {
		t.Errorf("extra = %+v", x)
	}
	// The top-level form, with a monthly spend window.
	_, w, _ = ParseGrokBilling([]byte(`{"monthlyLimit":{"val":"100"},"used":{"val":"25"},"billingPeriodEnd":"2026-12-01T00:00:00Z"}`))
	if len(w) != 1 || w[0].Minutes != 43200 || w[0].UsedPct != 25 {
		t.Errorf("monthly = %+v", w)
	}
	// A missing percentage is 0 only under a weekly period that is the
	// billing period.
	weekly := `"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-23T00:00:00Z","end":"2026-11-30T00:00:00Z"},"billingPeriodStart":"2026-11-23T00:00:00Z","billingPeriodEnd":"2026-11-30T00:00:00Z"`
	if _, w, _ := ParseGrokBilling([]byte(`{` + weekly + `}`)); len(w) != 1 || w[0].UsedPct != 0 {
		t.Errorf("a confirmed weekly period with no percentage = %+v, want 0%% used", w)
	}
	// xAI wrote a zero elsewhere, so the missing percentage is missing.
	if _, w, _ := ParseGrokBilling([]byte(`{` + weekly + `,"prepaidBalance":{"val":"0"}}`)); len(w) != 0 {
		t.Errorf("an unreported percentage became %+v", w)
	}
	if _, w, _ := ParseGrokBilling([]byte(`{"subscriptionTier":"SuperGrok"}`)); len(w) != 0 {
		t.Errorf("no figures became %+v", w)
	}
}

// vendorStub points both vendor addresses at a test server for one test.
func vendorStub(t *testing.T, h http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewServer(h)
	oc, og := claudeUsageURL, grokBillingURL
	claudeUsageURL, grokBillingURL = srv.URL+"/api/oauth/usage", srv.URL+"/v1/billing"
	t.Cleanup(func() { srv.Close(); claudeUsageURL, grokBillingURL = oc, og })
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestVendorUsageIsOffUnlessTurnedOn(t *testing.T) {
	dir, home := t.TempDir(), t.TempDir()
	stub(t, dir, "claude", `[ "$1" = auth ] && echo '{"planTier":"max_20x"}'; exit 0`)
	stub(t, dir, "grok", `echo "Available models:"; echo "* grok-4.7"`)
	write(t, filepath.Join(home, ".claude", ".credentials.json"), `{"claudeAiOauth":{"accessToken":"tok-claude"}}`)
	write(t, filepath.Join(home, ".grok", "auth.json"), `{"https://auth.x.ai":{"key":"tok-grok","user_id":"u1"}}`)
	asked := 0
	vendorStub(t, func(w http.ResponseWriter, r *http.Request) { asked++ })
	e := Env{BinDir: dir, Home: home}
	for _, h := range []string{"claude", "grok"} {
		rep, ok := Ask(context.Background(), e, h)
		if !ok || len(rep.Windows) != 0 || rep.UsageSource != "" || rep.UsageNote == "" {
			t.Errorf("%s = %+v", h, rep)
		}
	}
	if asked != 0 {
		t.Fatalf("a vendor was asked %d times with the lookup off", asked)
	}
}

func TestClaudeVendorUsage(t *testing.T) {
	dir, home := t.TempDir(), t.TempDir()
	stub(t, dir, "claude", `[ "$1" = auth ] && echo '{"planTier":"max_20x"}'; exit 0`)
	creds := filepath.Join(home, ".claude", ".credentials.json")
	write(t, creds, `{"claudeAiOauth":{"accessToken":"tok-claude","refreshToken":"never-sent","expiresAt":99999999999000}}`)
	status := http.StatusOK
	vendorStub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/oauth/usage" || r.Header.Get("Authorization") != "Bearer tok-claude" || r.Header.Get("anthropic-beta") == "" {
			t.Errorf("request = %s %s %v", r.Method, r.URL, r.Header)
		}
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		_, _ = w.Write([]byte(`{"five_hour":{"utilization":20,"resets_at":"2026-11-28T15:00:00Z"},"seven_day":{"utilization":55}}`))
	})
	e := Env{BinDir: dir, Home: home}
	on := AskOptions{VendorUsage: true}
	before, _ := os.ReadFile(creds)

	rep, _ := AskWith(context.Background(), e, "claude", on)
	if len(rep.Windows) != 2 || rep.Windows[1].UsedPct != 55 || rep.UsageSource != SourceVendor || rep.UsageNote != "" || rep.Plan != "max_20x" {
		t.Fatalf("claude = %+v", rep)
	}
	// A refused login gives no figure and a reason without the login in it.
	status = http.StatusUnauthorized
	rep, _ = AskWith(context.Background(), e, "claude", on)
	if len(rep.Windows) != 0 || rep.UsageSource != "" || !strings.Contains(rep.UsageNote, "refused") || strings.Contains(rep.UsageNote, "tok-") {
		t.Errorf("refused = %+v", rep)
	}
	status = http.StatusTooManyRequests
	if rep, _ = AskWith(context.Background(), e, "claude", on); len(rep.Windows) != 0 || !strings.Contains(rep.UsageNote, "429") {
		t.Errorf("busy = %+v", rep)
	}
	// The login file is only ever read.
	if after, _ := os.ReadFile(creds); string(after) != string(before) {
		t.Error("the login file was changed")
	}
	// An expired login is left for Claude Code to renew: nothing is sent.
	status = http.StatusOK
	write(t, creds, `{"claudeAiOauth":{"accessToken":"tok-claude","expiresAt":1000}}`)
	sent := false
	vendorStub(t, func(http.ResponseWriter, *http.Request) { sent = true })
	if rep, _ = AskWith(context.Background(), e, "claude", on); sent || len(rep.Windows) != 0 || !strings.Contains(rep.UsageNote, "expired") {
		t.Errorf("expired = %+v (sent %v)", rep, sent)
	}
	// No login file: said plainly.
	if err := os.Remove(creds); err != nil {
		t.Fatal(err)
	}
	if rep, _ = AskWith(context.Background(), e, "claude", on); sent || rep.UsageNote == "" || len(rep.Windows) != 0 {
		t.Errorf("no login = %+v", rep)
	}
}

func TestGrokVendorUsage(t *testing.T) {
	dir, home := t.TempDir(), t.TempDir()
	stub(t, dir, "grok", `echo "Available models:"; echo "* grok-4.7"`)
	write(t, filepath.Join(home, ".grok", "auth.json"),
		`{"https://other.example":{"key":"tok-other"},"https://auth.x.ai::cli":{"key":"tok-grok","user_id":"u1","expires_at":"2999-01-01T00:00:00Z"}}`)
	var paths []string
	vendorStub(t, func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.RequestURI())
		if r.Header.Get("Authorization") != "Bearer tok-grok" || r.Header.Get("x-userid") != "u1" || r.Header.Get("X-XAI-Token-Auth") != "xai-grok-cli" {
			t.Errorf("headers = %v", r.Header)
		}
		if r.URL.RawQuery == "format=credits" {
			_, _ = w.Write([]byte(`{"config":{"subscriptionTier":"SuperGrok"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"monthlyLimit":{"val":"100"},"used":{"val":"40"}}`))
	})
	rep, _ := AskWith(context.Background(), Env{BinDir: dir, Home: home}, "grok", AskOptions{VendorUsage: true})
	if len(paths) != 2 || paths[0] != "/v1/billing?format=credits" || paths[1] != "/v1/billing" {
		t.Errorf("asked %v", paths)
	}
	if rep.Plan != "SuperGrok" || len(rep.Windows) != 1 || rep.Windows[0].UsedPct != 40 || rep.UsageSource != SourceVendor || !rep.ModelsKnown {
		t.Errorf("grok = %+v", rep)
	}
}

func TestVendorLookupsFollowNoRedirect(t *testing.T) {
	dir, home := t.TempDir(), t.TempDir()
	stub(t, dir, "claude", `exit 0`)
	write(t, filepath.Join(home, ".claude", ".credentials.json"), `{"claudeAiOauth":{"accessToken":"tok-claude"}}`)
	elsewhere := 0
	other := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { elsewhere++ }))
	defer other.Close()
	vendorStub(t, func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, other.URL, http.StatusFound) })
	rep, _ := AskWith(context.Background(), Env{BinDir: dir, Home: home}, "claude", AskOptions{VendorUsage: true})
	if elsewhere != 0 || len(rep.Windows) != 0 || rep.UsageNote == "" {
		t.Errorf("redirect followed %d times; %+v", elsewhere, rep)
	}
}

func TestVendorLookups(t *testing.T) {
	var names []string
	for _, l := range VendorLookups() {
		names = append(names, l.Harness+"="+l.Vendor)
	}
	if strings.Join(names, ",") != "claude=Anthropic,grok=xAI" {
		t.Errorf("lookups = %v", names)
	}
	if HasVendorLookup("agy") || !HasVendorLookup("grok") {
		t.Error("HasVendorLookup is wrong")
	}
}
