package router

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

func measured(used float64, window string, resetIn time.Duration, now time.Time) Pool {
	r := now.Add(resetIn).UTC().Format(time.RFC3339)
	return Pool{State: "available", QuotaSource: "codex_rate_limits", UsedPct: &used, ResetsAt: &r, Window: window}
}

func TestPace(t *testing.T) {
	now := time.Unix(1795000000, 0)
	week := 7 * 24 * time.Hour

	// 9 h left of the week with 40% used: most of the week goes unused.
	pc := pace(measured(40, "weekly", 9*time.Hour, now), now)
	if pc == nil || pc.UnusedAtResetPct == nil || *pc.UnusedAtResetPct != 58 || pc.RunsOutAt != nil {
		t.Fatalf("unused: %+v", pc)
	}
	if pc.Adjustment <= 3 || pc.Adjustment > PaceMaxAdjustment {
		t.Errorf("near the reset with 58%% unused the lean is strong: %v", pc.Adjustment)
	}
	if got := PaceText(pc, now, time.UTC); got != "weekly window resets in 9h with ~58% unused at this rate" {
		t.Errorf("text %q", got)
	}

	// Two days in with 60% used: it runs dry before the week is out.
	pc = pace(measured(60, "weekly", week-48*time.Hour, now), now)
	if pc == nil || pc.RunsOutAt == nil || pc.UnusedAtResetPct != nil || pc.Adjustment >= 0 || pc.Adjustment < -PaceMaxAdjustment {
		t.Fatalf("runs out: %+v", pc)
	}
	dry, _ := time.Parse(time.RFC3339, *pc.RunsOutAt)
	if want := now.Add(32 * time.Hour); dry.Sub(want).Abs() > time.Minute {
		t.Errorf("runs out %v, want %v (40%% left at 30%%/day)", dry, want)
	}
	if got := PaceText(pc, now, time.UTC); !strings.Contains(got, "runs out") || !strings.Contains(got, "before it resets in 5d") {
		t.Errorf("text %q", got)
	}

	// Too early in the window: shown, not projected.
	pc = pace(measured(5, "5h", 4*time.Hour+50*time.Minute, now), now)
	if pc == nil || pc.Adjustment != 0 || pc.UnusedAtResetPct != nil || !strings.Contains(PaceText(pc, now, time.UTC), "too early") {
		t.Errorf("early: %+v", pc)
	}

	// An estimate, or a spent pool, has no pace to lean on.
	est := measured(40, "weekly", 9*time.Hour, now)
	est.QuotaSource = "local_5h_activity"
	if pace(est, now) != nil {
		t.Error("an estimate was projected")
	}
	if pc := pace(measured(100, "5h", time.Hour, now), now); pc == nil || pc.Adjustment != 0 {
		t.Errorf("spent: %+v", pc)
	}
	// A reset further off than the window is long is not this window.
	if pace(measured(40, "5h", 6*time.Hour, now), now) != nil {
		t.Error("a reset beyond the window was projected")
	}
}

func TestPacingMovesTheScoreOnlyWhenOn(t *testing.T) {
	now := time.Unix(1795000000, 0)
	pool := measured(40, "weekly", 9*time.Hour, now)
	pool.Pacing = pace(pool, now)
	probe := &Probe{Harnesses: map[string]HarnessState{"claude": {Installed: true}}, Pools: map[string]Pool{"anthropic-max": pool}, at: now}
	r := &Router{Catalog: DefaultCatalog(), Probe: probe}
	in := Input{Stage: "build", Risk: "medium", OnlyHarnesses: []string{"claude"}}
	off := r.Select(in)
	if off.IsFallback() || off.PacingAdjustment != nil || off.Pacing == nil {
		t.Fatalf("pacing off: %+v", off)
	}
	r.Pacing = true
	on := r.Select(in)
	if on.PacingAdjustment == nil || *on.PacingAdjustment != pool.Pacing.Adjustment {
		t.Fatalf("pacing on: %+v", on.PacingAdjustment)
	}
	if d := on.EffectiveScore - off.EffectiveScore; d < *on.PacingAdjustment-0.01 || d > *on.PacingAdjustment+0.01 {
		t.Errorf("score moved %v, want %v", d, *on.PacingAdjustment)
	}
	if !strings.Contains(on.Reason, "pacing: weekly window resets in 9h with ~58% unused") {
		t.Errorf("reason %q", on.Reason)
	}
}

func TestCodexReadingKeepsTheFullerWindowsReset(t *testing.T) {
	now := int64(1795000000)
	doc := `{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":` + itoa64(now+3600) + `},"secondary":{"used_percent":70,"window_minutes":10080,"resets_at":` + itoa64(now+86400) + `}}}`
	q, ok := parseCodexRateLimits([]byte(doc), now)
	if !ok || q.UsedPct != 70 || q.Window != "weekly" || q.ResetsAtEpoch == nil || int64(*q.ResetsAtEpoch) != now+86400 {
		t.Fatalf("%+v %v", q, ok)
	}
}

func itoa64(n int64) string { return strconv.FormatInt(n, 10) }
