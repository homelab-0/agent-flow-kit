package router

import (
	"fmt"
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
	// Refused while another window still had room: the named limit is
	// full, and the pool is back when that limit resets.
	rejNamed := []byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":1795003600,"unifiedWindows":{"seven_day":{"utilization":0.6,"resetsAt":1795813200,"status":"allowed"}}}}`)
	if u, ok = ParseClaudeUsage(rejNamed, now); !ok || u.UsedPct != 100 || u.ResetsAt != 1795003600 || u.FiveHourPct == nil || *u.FiveHourPct != 100 || *u.SevenDayPct != 60 {
		t.Fatalf("rejected with a named limit: %+v %v", u, ok)
	}
	// A refusal whose limit has since reset: the live weekly reading stands.
	rejOver := []byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":1794999000,"unifiedWindows":{"five_hour":{"utilization":1,"resetsAt":1794999000,"status":"rejected"},"seven_day":{"utilization":0.6,"resetsAt":1795813200,"status":"allowed"}}}}`)
	if u, ok = ParseClaudeUsage(rejOver, now); !ok || u.UsedPct != 60 || u.ResetsAt != 1795813200 || u.Window != "weekly" || u.FiveHourPct != nil {
		t.Fatalf("refusal already over: %+v %v", u, ok)
	}
	// The window chosen is carried, even when both round to the same figure.
	same := []byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day","resetsAt":1795813200,"unifiedWindows":{"five_hour":{"utilization":0.999,"resetsAt":1795003600}}}}`)
	if u, ok = ParseClaudeUsage(same, now); !ok || u.Window != "weekly" || u.ResetsAt != 1795813200 || *u.FiveHourPct != 100 {
		t.Fatalf("named window: %+v %v", u, ok)
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

func TestASignalHidesTheReadingsWindows(t *testing.T) {
	home := t.TempDir()
	now := time.Unix(1795000000, 0)
	usage := filepath.Join(home, "plan-usage.json")
	sig := filepath.Join(home, "sig.json")
	weekly := 40.0
	if err := RecordPlanUsage(usage, "anthropic-max", PlanUsage{UsedPct: 40, SevenDayPct: &weekly, ResetsAt: now.Unix() + 3*86400, Observed: now.Unix() - 60, Source: "claude_rate_limit_event"}); err != nil {
		t.Fatal(err)
	}
	doc := fmt.Sprintf(`{"pools":{"anthropic-max":{"used_pct":100,"degraded_reason":"429 Too Many Requests","degraded_kind":"quota","updated_epoch":%d}}}`, now.Unix()-30)
	if err := os.WriteFile(sig, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"AFK_PLAN_USAGE_FILE": usage, "AFK_ROUTER_SIGNALS_FILE": sig}
	probe := func() Pool {
		p := ProbePools(t.Context(), DefaultCatalog(), ProbeEnv{Home: home, Now: now, Getenv: func(k string) string { return env[k] }, Installed: func(string) bool { return true }})
		return p.Pools["anthropic-max"]
	}
	pool := probe()
	if pool.State != "exhausted" || pool.QuotaSource != "runtime_signal:quota" || pool.WeeklyUsedPct != nil || pool.ResetsAt != nil {
		t.Fatalf("under a signal the reading's 40%% weekly must not show: %+v", pool)
	}
	// Signal gone: the reading speaks again.
	if err := os.Remove(sig); err != nil {
		t.Fatal(err)
	}
	if pool = probe(); pool.QuotaSource != "claude_rate_limit_event" || pool.WeeklyUsedPct == nil || *pool.WeeklyUsedPct != 40 || pool.ResetsAt == nil {
		t.Fatalf("reading: %+v", pool)
	}
}
