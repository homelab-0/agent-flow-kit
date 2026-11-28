package harness

import (
	"context"
	"encoding/json"
	"path/filepath"
	"time"
)

// Anthropic's usage service, as Claude Code's own /usage screen asks it
// (checked against Claude Code 2.1.332's login file).
//
// GET https://api.anthropic.com/api/oauth/usage with the access token
// Claude Code saved answers
//
//	{"five_hour":{"utilization":12,"resets_at":"2026-11-28T15:00:00Z"},
//	 "seven_day":{"utilization":40,"resets_at":"..."},
//	 "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250}}
//
// The login is ~/.claude/.credentials.json (CLAUDE_CONFIG_DIR moves it).
// On macOS Claude Code keeps it in the keychain, which AFK doesn't open:
// there the lookup says so and gives no figure.

var claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"

func (claudeReporter) Vendor() string { return "Anthropic" }

func (claudeReporter) VendorUsage(ctx context.Context, e Env, rep *Account) {
	dir := e.getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		dir = filepath.Join(e.Home, ".claude")
	}
	raw, ok := readLogin(filepath.Join(dir, ".credentials.json"))
	if !ok {
		rep.UsageNote = "Claude Code's saved login isn't in a file here, so Anthropic can't be asked"
		return
	}
	var login struct {
		OAuth struct {
			AccessToken string          `json:"accessToken"`
			ExpiresAt   json.RawMessage `json:"expiresAt"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(raw, &login) != nil || login.OAuth.AccessToken == "" {
		rep.UsageNote = "Claude Code isn't signed in with a plan, so Anthropic can't be asked"
		return
	}
	if at := flexTime(login.OAuth.ExpiresAt); at != 0 && at <= time.Now().Unix() {
		// Renewing a login is Claude Code's job; AFK never does it.
		rep.UsageNote = "Claude Code's saved login has expired; open claude once to renew it"
		return
	}
	body, err := vendorGet(ctx, claudeUsageURL, map[string]string{
		"Authorization":  "Bearer " + login.OAuth.AccessToken,
		"anthropic-beta": "oauth-2025-04-20",
		"Accept":         "application/json",
	})
	if err != nil {
		rep.UsageNote = vendorNote("Anthropic", "claude", err)
		return
	}
	windows, extra := ParseClaudeUsage(body)
	if len(windows) == 0 {
		rep.UsageNote = "Anthropic's usage service gave no figure (nothing in its answer)"
		return
	}
	rep.Windows, rep.UsageNote, rep.UsageSource = windows, "", SourceVendor
	if extra != nil {
		rep.Extra = extra
	}
}

// ParseClaudeUsage reads Anthropic's usage answer: the 5-hour and weekly
// windows, and extra usage when the answer has it. Windows scoped to one
// model are left out; Window has no place for them yet.
func ParseClaudeUsage(body []byte) ([]Window, *Extra) {
	type window struct {
		Utilization    *float64        `json:"utilization"`
		UsedPercentage *float64        `json:"used_percentage"`
		ResetsAt       json.RawMessage `json:"resets_at"`
	}
	var d struct {
		FiveHour *window `json:"five_hour"`
		SevenDay *window `json:"seven_day"`
		Extra    *struct {
			IsEnabled     bool     `json:"is_enabled"`
			MonthlyLimit  *float64 `json:"monthly_limit"`
			UsedCredits   *float64 `json:"used_credits"`
			Currency      string   `json:"currency"`
			DecimalPlaces *int     `json:"decimal_places"`
		} `json:"extra_usage"`
	}
	if json.Unmarshal(body, &d) != nil {
		return nil, nil
	}
	var out []Window
	add := func(w *window, minutes int) {
		if w == nil {
			return
		}
		used := w.Utilization
		if used == nil {
			used = w.UsedPercentage
		}
		if used == nil {
			return
		}
		out = append(out, Window{Minutes: minutes, UsedPct: pct(*used), ResetsAt: flexTime(w.ResetsAt)})
	}
	add(d.FiveHour, 300)
	add(d.SevenDay, 10080)
	if d.Extra == nil {
		return out, nil
	}
	x := &Extra{Enabled: d.Extra.IsEnabled, Currency: d.Extra.Currency}
	// Amounts come in the currency's smallest unit (cents).
	places := 2
	if p := d.Extra.DecimalPlaces; p != nil && *p >= 0 && *p <= 6 {
		places = *p
	}
	div := 1.0
	for i := 0; i < places; i++ {
		div *= 10
	}
	if l := d.Extra.MonthlyLimit; l != nil && *l > 0 {
		x.Limit = money(*l / div)
		if u := d.Extra.UsedCredits; u != nil && *u >= 0 {
			x.Spent = money(*u / div)
		}
		if x.Currency == "" {
			x.Currency = "USD"
		}
	}
	return out, x
}
