package router

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseClaudeUsage(t *testing.T) {
	b, err := os.ReadFile("../oneshot/testdata/claude-stream-ok.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1795000000, 0)
	u, ok := ParseClaudeUsage(b, now)
	if !ok || u.UsedPct != 17 || u.SevenDayPct == nil || *u.SevenDayPct != 17 || u.FiveHourPct != nil || u.ResetsAt != 1795813200 {
		t.Fatalf("usage %+v %v (the overage window must not count)", u, ok)
	}
	// The fuller window wins, and a rejected one is spent.
	two := []byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.62,"resetsAt":1795003600},"seven_day":{"utilization":0.3,"resetsAt":1795813200}}}}`)
	u, ok = ParseClaudeUsage(two, now)
	if !ok || u.UsedPct != 62 || u.ResetsAt != 1795003600 || *u.FiveHourPct != 62 || *u.SevenDayPct != 30 {
		t.Fatalf("two windows: %+v", u)
	}
	rej := []byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1795003600}}`)
	if u, ok = ParseClaudeUsage(rej, now); !ok || u.UsedPct != 100 || u.ResetsAt != 1795003600 {
		t.Fatalf("rejected: %+v %v", u, ok)
	}
	if _, ok := ParseClaudeUsage([]byte(`{"type":"result","result":"ok"}`), now); ok {
		t.Error("no event, yet a reading")
	}
	// A window that already reset says nothing about now.
	old := []byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.9,"resetsAt":1794990000}}}}`)
	if _, ok := ParseClaudeUsage(old, now); ok {
		t.Error("a reset window counted")
	}
}

func TestPlanUsageStandsUntilItsWindowResets(t *testing.T) {
	path := filepath.Join(t.TempDir(), "plan-usage.json")
	now := time.Unix(1795000000, 0)
	if err := RecordPlanUsage(path, "anthropic-max", PlanUsage{UsedPct: 40, ResetsAt: now.Unix() + 3600, Observed: now.Unix(), Source: "claude_rate_limit_event"}); err != nil {
		t.Fatal(err)
	}
	if q, ok := readPlanUsage(path, "anthropic-max", now.Add(time.Hour-time.Minute)); !ok || q.UsedPct != 40 || q.ResetsAtEpoch == nil {
		t.Fatalf("fresh reading: %+v %v", q, ok)
	}
	if _, ok := readPlanUsage(path, "anthropic-max", now.Add(time.Hour)); ok {
		t.Error("a reading stood past its reset")
	}
	if err := RecordPlanUsage(path, "anthropic-max", PlanUsage{UsedPct: 40, Observed: now.Unix()}); err != nil {
		t.Fatal(err)
	}
	if _, ok := readPlanUsage(path, "anthropic-max", now.Add(UsageMaxAge+time.Second)); ok {
		t.Error("a reading stood past UsageMaxAge")
	}
}

func TestProbeUsesClaudesReportedUsage(t *testing.T) {
	home := t.TempDir()
	now := time.Unix(1795000000, 0)
	usage := filepath.Join(home, "plan-usage.json")
	if err := RecordPlanUsage(usage, "anthropic-max", PlanUsage{UsedPct: 80, ResetsAt: now.Unix() + 7200, Observed: now.Unix() - 60, Source: "claude_rate_limit_event"}); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"AFK_PLAN_USAGE_FILE": usage, "AFK_ROUTER_SIGNALS_FILE": filepath.Join(home, "sig.json")}
	p := ProbePools(t.Context(), DefaultCatalog(), ProbeEnv{Home: home, Now: now, Getenv: func(k string) string { return env[k] }, Installed: func(string) bool { return true }})
	pool := p.Pools["anthropic-max"]
	if pool.QuotaSource != "claude_rate_limit_event" || pool.UsedPct == nil || *pool.UsedPct != 80 || pool.State != "warning" {
		t.Fatalf("pool %+v", pool)
	}
	if pool.ResetsAt == nil || *pool.ResetsAt != time.Unix(now.Unix()+7200, 0).UTC().Format(time.RFC3339) {
		t.Errorf("resets_at %v", pool.ResetsAt)
	}
}
