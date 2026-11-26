package router

import (
	"bytes"
	"encoding/json"
	"math"
	"os"
	"strings"
	"time"
)

// Plan usage that a CLI reports in its own output, kept between runs.
//
// Claude Code's stream-json output (claude -p --output-format stream-json
// --verbose) carries a rate_limit_event with the plan's utilization per
// window and when each resets. AFK reads it from the output of the runs it
// starts, so no login is read and nothing extra is sent. Interactive
// sessions don't print it, so a reading is as of AFK's last one-shot run.

// UsageMaxAge is how long a reading stands in for the estimate, if its
// window hasn't reset by then.
const UsageMaxAge = 12 * time.Hour

// PlanUsage is one reading.
type PlanUsage struct {
	UsedPct     float64  `json:"used_pct"`
	FiveHourPct *float64 `json:"five_hour_pct,omitempty"`
	SevenDayPct *float64 `json:"seven_day_pct,omitempty"`
	// ResetsAt is when the fullest window resets (unix seconds), 0 unknown.
	ResetsAt int64  `json:"resets_at_epoch,omitempty"`
	Observed int64  `json:"observed_epoch"`
	Source   string `json:"source"`
}

// UsagePath is where readings are kept.
func (e ProbeEnv) UsagePath() string {
	return e.path("AFK_PLAN_USAGE_FILE", ".config/afk/state/plan-usage.json")
}

type claudeWindow struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *float64 `json:"resetsAt"`
	Status      string   `json:"status"`
}

type claudeRateEvent struct {
	Type string `json:"type"`
	Info *struct {
		Status         string                  `json:"status"`
		RateLimitType  string                  `json:"rateLimitType"`
		ResetsAt       *float64                `json:"resetsAt"`
		UnifiedWindows map[string]claudeWindow `json:"unifiedWindows"`
	} `json:"rate_limit_info"`
}

// ParseClaudeUsage reads the last rate_limit_event in Claude's stream-json
// output. Only the plan's own windows count (five_hour and seven_day, plus
// any other window that isn't an overage one). A rejected status is a
// spent plan. ok is false when the output has no usable event.
func ParseClaudeUsage(stdout []byte, now time.Time) (PlanUsage, bool) {
	// stream-json is one JSON document per line.
	var last *claudeRateEvent
	for _, line := range bytes.Split(stdout, []byte("\n")) {
		if !bytes.Contains(line, []byte(`"rate_limit_event"`)) {
			continue
		}
		var ev claudeRateEvent
		if json.Unmarshal(line, &ev) == nil && ev.Type == "rate_limit_event" && ev.Info != nil {
			last = &ev
		}
	}
	if last == nil {
		return PlanUsage{}, false
	}
	u := PlanUsage{Observed: now.Unix(), Source: "claude_rate_limit_event"}
	found := false
	used := 0.0
	for name, w := range last.Info.UnifiedWindows {
		if w.Utilization == nil || strings.Contains(name, "overage") {
			continue
		}
		if w.ResetsAt != nil && int64(*w.ResetsAt) <= now.Unix() {
			continue
		}
		pct := math.Max(0, math.Min(100, *w.Utilization*100))
		if w.Status == "rejected" {
			pct = 100
		}
		r := math.Round(pct)
		switch name {
		case "five_hour":
			u.FiveHourPct = &r
		case "seven_day":
			u.SevenDayPct = &r
		}
		if !found || pct > used {
			used = pct
			u.ResetsAt = 0
			if w.ResetsAt != nil {
				u.ResetsAt = int64(*w.ResetsAt)
			}
		}
		found = true
	}
	if last.Info.Status == "rejected" {
		used, found = 100, true
		if u.ResetsAt == 0 && last.Info.ResetsAt != nil {
			u.ResetsAt = int64(*last.Info.ResetsAt)
		}
	}
	if !found {
		return PlanUsage{}, false
	}
	u.UsedPct = math.Round(used)
	return u, true
}

// RecordPlanUsage keeps a reading for a pool, under the same kind of lock
// as the signals file.
func RecordPlanUsage(path, pool string, u PlanUsage) error {
	if pool == "" {
		return nil
	}
	return updateSignals(path, func(doc map[string]any) {
		pools, _ := doc["pools"].(map[string]any)
		if pools == nil {
			pools = map[string]any{}
		}
		b, _ := json.Marshal(u)
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		pools[pool] = m
		doc["pools"] = pools
	})
}

// readPlanUsage returns a pool's reading while it still stands: younger
// than UsageMaxAge and its window not yet reset.
func readPlanUsage(path, pool string, now time.Time) (quota, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return quota{}, false
	}
	var doc struct {
		Pools map[string]PlanUsage `json:"pools"`
	}
	if json.Unmarshal(b, &doc) != nil {
		return quota{}, false
	}
	u, ok := doc.Pools[pool]
	if !ok || u.Observed == 0 || now.Unix()-u.Observed > int64(UsageMaxAge/time.Second) || now.Unix() < u.Observed-300 {
		return quota{}, false
	}
	if u.ResetsAt != 0 && u.ResetsAt <= now.Unix() {
		return quota{}, false
	}
	q := quota{OK: true, Source: u.Source, UsedPct: u.UsedPct, FiveHourPct: u.FiveHourPct, SevenDayPct: u.SevenDayPct}
	if q.Source == "" {
		q.Source = "plan_usage"
	}
	if u.ResetsAt != 0 {
		r := float64(u.ResetsAt)
		q.ResetsAtEpoch = &r
	}
	return q, true
}
