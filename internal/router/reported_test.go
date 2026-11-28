package router

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
)

// reportedProbe is a probe where every plan CLI is installed and signed
// in, and each reported what accounts says.
func reportedProbe(t *testing.T, accounts map[string]harness.Account) *Probe {
	t.Helper()
	home := t.TempDir()
	// Signed in, as far as the probe looks: a login file that isn't empty.
	for _, f := range []string{".grok/auth.json", ".gemini/antigravity-cli/settings.json"} {
		p := filepath.Join(home, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(`{"signed":"in"}`), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	e := ProbeEnv{
		Home: home, Getenv: func(string) string { return "" }, Now: time.Unix(1_796_000_000, 0),
		Installed: func(h string) bool { return h == "claude" || h == "codex" || h == "agy" || h == "grok" },
		Account: func(_ context.Context, h string) (harness.Account, bool) {
			a, ok := accounts[h]
			return a, ok
		},
	}
	return ProbePools(context.Background(), DefaultCatalog(), e)
}

func routeFor(t *testing.T, p *Probe, only string) Route {
	t.Helper()
	r := &Router{Catalog: DefaultCatalog(), Probe: p}
	return r.Select(Input{Stage: "build", Risk: "medium", OnlyHarnesses: []string{only}, Now: time.Unix(1_796_000_000, 0)})
}

func TestACLIIsRoutedOnlyToTheModelsItReported(t *testing.T) {
	p := reportedProbe(t, map[string]harness.Account{
		// The plan doesn't include gemini-4-carbon, so agy doesn't list it.
		"agy": {ModelsKnown: true, Models: []string{
			"gemini-4-hydrogen-high", "gemini-4-hydrogen-medium", "gemini-4-hydrogen-low",
			"gemini-3.8-flash-high", "claude-sonnet-4-6",
		}, UsageNote: "Antigravity doesn't report plan usage"},
		"grok": {ModelsKnown: true, Models: []string{"grok-4.7", "grok-4.6"}},
	})
	agy := routeFor(t, p, "agy")
	if agy.IsFallback() || agy.Harness != "agy" {
		t.Fatalf("agy should still route, got %+v", agy)
	}
	if agy.Model == "gemini-4-carbon" {
		t.Fatal("routed to a model agy didn't list")
	}
	if agy.Model != "gemini-4-hydrogen" || agy.BenchmarkBasis != BasisUnrated {
		t.Errorf("agy route = %s (%s), want the first listed model, unrated", agy.Model, agy.BenchmarkBasis)
	}
	if !contains(agy.SupportedEfforts, "high") || !contains(agy.SupportedEfforts, "low") {
		t.Errorf("efforts come from the listed tiers, got %v", agy.SupportedEfforts)
	}
	if agy.PoolUsageNote == "" || agy.PoolHeadroomPct != nil {
		t.Errorf("no usage figure, and the reason why: got %q / %v", agy.PoolUsageNote, agy.PoolHeadroomPct)
	}
	// A listed catalog model keeps its catalog entry and score.
	grok := routeFor(t, p, "grok")
	if grok.Model != "grok-4.7" || grok.BenchmarkBasis == BasisUnrated {
		t.Errorf("grok route = %s (%s)", grok.Model, grok.BenchmarkBasis)
	}
	// Claude Code lists nothing: it is routed from the catalog, as before.
	if c := routeFor(t, p, "claude"); c.IsFallback() || c.Harness != "claude" {
		t.Errorf("claude route = %+v", c)
	}
}

func TestAModelWithoutATierHasNoEffort(t *testing.T) {
	p := reportedProbe(t, map[string]harness.Account{
		"agy": {ModelsKnown: true, Models: []string{"claude-sonnet-4-6", "gpt-oss-120b-medium"}},
	})
	cands := withReported(nil, p)
	if len(cands) != 2 {
		t.Fatalf("candidates = %+v", cands)
	}
	if c := cands[0]; c.Model != "claude-sonnet-4-6" || c.SupportedEfforts == nil || len(c.SupportedEfforts) != 0 || c.Effort != "" {
		t.Errorf("untiered model: %+v", c)
	}
	if c := cands[1]; c.Model != "gpt-oss-120b" || len(c.SupportedEfforts) != 1 || c.Effort != "medium" {
		t.Errorf("tiered model: %+v", c)
	}
}

func TestCodexUsageComesFromItsOwnReport(t *testing.T) {
	now := int64(1_796_000_000)
	p := reportedProbe(t, map[string]harness.Account{
		"codex": {
			Plan: "pro", ModelsKnown: true, Models: []string{"gpt-6.2-sol", "gpt-6-astra"}, At: now,
			Windows: []harness.Window{{Minutes: 10080, UsedPct: 30, ResetsAt: now + 3600}, {Minutes: 300, UsedPct: 12, ResetsAt: now + 600}},
			Extra:   &harness.Extra{Enabled: true, Balance: "56656.97"},
		},
	})
	st := p.Harnesses["codex"]
	q, ok := accountQuota(st, "codex_app_server", now)
	if !ok || q.UsedPct != 30 || q.Window != "weekly" || *q.FiveHourPct != 12 || *q.SevenDayPct != 30 {
		t.Fatalf("quota = %+v", q)
	}
	// An expired window is not a reading.
	st.Windows = []harness.Window{{Minutes: 300, UsedPct: 90, ResetsAt: now - 1}}
	if _, ok := accountQuota(st, "codex_app_server", now); ok {
		t.Error("an expired window gave a figure")
	}
	pool := p.Pools["openai-plus"]
	if pool.Extra == nil || pool.Extra.Balance != "56656.97" {
		t.Errorf("extra usage = %+v", pool.Extra)
	}
	// gpt-6.1-sol is in the catalog but not in the account's list.
	r := &Router{Catalog: DefaultCatalog(), Probe: p}
	for _, c := range withReported(r.candidates(false), p) {
		if c.Harness == "codex" && c.Model == "gpt-6.1-sol" {
			t.Error("codex kept a catalog model it didn't list")
		}
	}
}
